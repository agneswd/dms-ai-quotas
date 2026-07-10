import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("aiQuotas.curlCheck", ["which", "curl"], (stdout, exitCode) => {
            if (exitCode === 0) {
                Proc.runCommand("aiQuotas.jqCheck", ["which", "jq"], (stdout2, exitCode2) => {
                    if (exitCode2 === 0) {
                        done(null)
                        return
                    }
                    done({
                        title: I18n.tr("jq is required"),
                        details: I18n.tr("Install jq with your package manager (e.g. `pacman -S jq` or `dnf install jq`).")
                    })
                })
                return
            }
            done({
                title: I18n.tr("curl is required"),
                details: I18n.tr("Install curl with your package manager (e.g. `pacman -S curl`).")
            })
        })
    }
}
