import Foundation
import Capacitor
import AuthenticationServices

/// Eigen, kleine plugin voor "Inloggen met Apple".
///
/// Waarom zelfgebouwd: Apple wees versie 1.1 af omdat de app voor het inloggen
/// naar Safari sprong (richtlijn 4). De kant-en-klare plugins voor Capacitor 8
/// slepen allemaal de Facebook-SDK mee, en die willen we niet in deze app.
/// Dit bestand doet precies één ding: het systeemvenster van Apple tonen en het
/// identiteitstoken teruggeven aan de webapp, die daarmee bij Supabase inlogt.
///
/// Aanroepen vanuit JavaScript:
///     const res = await window.Capacitor.Plugins.AppleLogin.authorize();
///     res.identityToken   // door te geven aan supabase.auth.signInWithIdToken
@objc(AppleLoginPlugin)
public class AppleLoginPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "AppleLoginPlugin"
    public let jsName = "AppleLogin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "authorize", returnType: CAPPluginReturnPromise)
    ]

    private var lopendeCall: CAPPluginCall?

    @objc func authorize(_ call: CAPPluginCall) {
        self.lopendeCall = call
        DispatchQueue.main.async {
            let verzoek = ASAuthorizationAppleIDProvider().createRequest()
            verzoek.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [verzoek])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func rondAf(_ blok: (CAPPluginCall) -> Void) {
        guard let call = self.lopendeCall else { return }
        self.lopendeCall = nil
        blok(call)
    }
}

extension AppleLoginPlugin: ASAuthorizationControllerDelegate {

    public func authorizationController(controller: ASAuthorizationController,
                                        didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let gegevens = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = gegevens.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            rondAf { $0.reject("Apple gaf geen identiteitstoken terug", "GEEN_TOKEN") }
            return
        }

        var resultaat: [String: Any] = [
            "identityToken": token,
            "user": gegevens.user
        ]

        // E-mail en naam geeft Apple alleen de allereerste keer mee.
        if let email = gegevens.email {
            resultaat["email"] = email
        }
        if let naam = gegevens.fullName {
            let volledig = [naam.givenName, naam.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !volledig.isEmpty {
                resultaat["naam"] = volledig
            }
        }

        rondAf { $0.resolve(resultaat) }
    }

    public func authorizationController(controller: ASAuthorizationController,
                                        didCompleteWithError error: Error) {
        let fout = error as NSError
        if fout.code == ASAuthorizationError.canceled.rawValue {
            rondAf { $0.reject("Geannuleerd", "GEANNULEERD") }
        } else {
            rondAf { $0.reject(error.localizedDescription, "MISLUKT") }
        }
    }
}

extension AppleLoginPlugin: ASAuthorizationControllerPresentationContextProviding {

    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let venster = self.bridge?.viewController?.view.window {
            return venster
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
