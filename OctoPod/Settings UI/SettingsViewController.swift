import UIKit

class SettingsViewController: ThemedStaticUITableViewController {

    @IBOutlet weak var printersLabel: UILabel!
    @IBOutlet weak var appearanceLabel: UILabel!
    @IBOutlet weak var securityLabel: UILabel!
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let theme = Theme.currentTheme()
        printersLabel.textColor = theme.textColor()
        appearanceLabel.textColor = theme.textColor()
        securityLabel.textColor = theme.textColor()
    }
}
