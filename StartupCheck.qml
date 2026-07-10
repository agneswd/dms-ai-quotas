import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("aiQuotas.depCheck", ["which", "opencode-quota"], (stdout, exitCode) => {
            if (exitCode === 0) {
                Proc.runCommand("aiQuotas.jqCheck", ["which", "jq"], (stdout2, exitCode2) => {
                    if (exitCode2 === 0) {
                        done(null)
                        return
                    }
                    done({
                        title: I18n.tr("jq is required"),
                        details: I18n.tr("The 'jq' tool is not installed or not on your PATH.\n\nInstall it with your package manager (e.g. `pacman -S jq` or `dnf install jq`).")
                    })
                })
                return
            }
            done({
                title: I18n.tr("opencode-quota is required"),
                details: I18n.tr("The 'opencode-quota' CLI is not installed or not on your PATH.\n\nInstall it with: npm i -g @slkiser/opencode-quota\n\nThen re-enable this plugin.")
            })
        })
    }
}
