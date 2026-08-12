import UIKit
import Capacitor

/// Eigen viewcontroller met één taak: onze zelfgeschreven AppleLogin-plugin
/// aanmelden bij Capacitor.
///
/// Plugins die uit een npm-pakket komen vindt Capacitor zelf. Een plugin die je
/// in dit project schrijft niet — die moet je hier registreren, anders bestaat
/// `window.Capacitor.Plugins.AppleLogin` niet en valt de app terug op de
/// inlogpagina in een browservenster.
///
/// Deze klasse is gekoppeld in Base.lproj/Main.storyboard
/// (customClass="MainViewController", customModule="CapApp_SPM").
@objc(MainViewController)
public class MainViewController: CAPBridgeViewController {

    public override func capacitorDidLoad() {
        bridge?.registerPluginInstance(AppleLoginPlugin())
    }
}
