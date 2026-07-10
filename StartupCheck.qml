import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("codexbar.depCheck", ["which", "codexbar"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null)
                return
            }
            done({
                title: I18n.tr("codexbar is required"),
                details: I18n.tr("The 'codexbar' CLI is not installed or not on your PATH.\n\nInstall it from https://github.com/steipete/CodexBar then re-enable this plugin.")
            })
        })
    }
}
