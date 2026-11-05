import Foundation
import CryptoKit

/// A reviewable fixed-purpose installer. Building a plan never executes it.
public struct AuthorizationPlan: Sendable {
    public static let helperPath = "/Library/PrivilegedHelperTools/net.nebula.gui/nebula-gui-helper"
    public static let plistPath = "/Library/LaunchDaemons/net.nebula.gui.helper.plist"
    public let script: String
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static let preflight = #"""
    set -eu
    umask 022
    ensure_directory() {
      if [ -L "$1" ]; then exit 70; fi
      if [ ! -e "$1" ]; then /bin/mkdir "$1"; fi
      [ -d "$1" ] || exit 70
      [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || exit 70
      mode=$(/usr/bin/stat -f %Lp "$1")
      [ $((0$mode & 022)) -eq 0 ] || exit 70
    }
    ensure_directory /Library
    ensure_directory /Library/PrivilegedHelperTools
    ensure_directory /Library/LaunchDaemons
    ensure_directory /Library/PrivilegedHelperTools/net.nebula.gui
    """#
    public static func install(bundle: URL, uid: UInt32, upgrading: Bool = false) throws -> AuthorizationPlan {
        guard uid > 0 else { throw BackendProblem(code: "invalid_user", message: "请用普通用户打开应用。") }
        let helper = bundle.appendingPathComponent("Contents/Helpers/nebula-gui-helper")
        let digest: String
        do {
            let values = try helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
            digest = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
        } catch { throw BackendProblem(code: "helper_missing", message: "应用缺少完整的网络组件，请重新构建。") }
        // No user-selected executable, shell command, config path or network key crosses this boundary.
        let prepare: String
        if upgrading {
            prepare = """
            for target in \(shellQuote(helperPath)) \(shellQuote(plistPath)); do
              [ -f "$target" ] && [ ! -L "$target" ] || exit 78
              [ "$(/usr/bin/stat -f %u "$target")" = 0 ] || exit 70
              mode=$(/usr/bin/stat -f %Lp "$target")
              [ $((0$mode & 022)) -eq 0 ] || exit 70
            done
            /usr/bin/sudo -u '#\(uid)' \(shellQuote(helperPath)) -health
            old_helper=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/net.nebula.gui/.backup.XXXXXX)
            old_plist=$(/usr/bin/mktemp /Library/LaunchDaemons/.nebula-gui-backup.XXXXXX)
            /bin/cp -p \(shellQuote(helperPath)) "$old_helper"
            /bin/cp -p \(shellQuote(plistPath)) "$old_plist"
            """
        } else {
            prepare = """
            if /bin/launchctl print system/net.nebula.gui.helper >/dev/null 2>&1; then exit 78; fi
            [ ! -e \(shellQuote(helperPath)) ] && [ ! -L \(shellQuote(helperPath)) ] || exit 78
            [ ! -e \(shellQuote(plistPath)) ] && [ ! -L \(shellQuote(plistPath)) ] || exit 78
            """
        }
        let script = preflight + "\n" + """
        if /bin/launchctl print system/com.slack.nebula >/dev/null 2>&1; then
          echo 'The previous Nebula service is still loaded.' >&2
          exit 73
        fi
        /bin/mkdir /Library/PrivilegedHelperTools/net.nebula.gui/.install-lock || exit 79
        stage=''
        plist_stage=''
        old_helper=''
        old_plist=''
        preserve_backups=0
        committed=0
        published=0
        cleanup() {
          [ -z "$stage" ] || /bin/rm -f "$stage"
          [ -z "$plist_stage" ] || /bin/rm -f "$plist_stage"
          if [ "$committed" -eq 0 ] && [ "$published" -eq 1 ]; then
            /bin/launchctl bootout --wait system/net.nebula.gui.helper >/dev/null 2>&1 || true
            if [ -n "$old_helper" ] && [ -n "$old_plist" ]; then
              if /bin/mv "$old_helper" \(shellQuote(helperPath)) && /bin/mv "$old_plist" \(shellQuote(plistPath)); then
                /bin/launchctl bootstrap system \(shellQuote(plistPath)) || echo 'Previous component could not restart.' >&2
              else
                preserve_backups=1
                echo 'Previous component could not be restored; protected backups retained.' >&2
              fi
            else
              /bin/rm -f \(shellQuote(helperPath)) \(shellQuote(plistPath))
            fi
          fi
          if [ "$preserve_backups" -eq 0 ]; then
            [ -z "$old_helper" ] || /bin/rm -f "$old_helper"
            [ -z "$old_plist" ] || /bin/rm -f "$old_plist"
          fi
          /bin/rmdir /Library/PrivilegedHelperTools/net.nebula.gui/.install-lock
        }
        trap cleanup EXIT
        \(prepare)
        stage=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/net.nebula.gui/.install.XXXXXX)
        plist_stage=$(/usr/bin/mktemp /Library/LaunchDaemons/.nebula-gui.XXXXXX)
        /bin/cp \(shellQuote(helper.path)) "$stage"
        actual=$(/usr/bin/shasum -a 256 "$stage" | /usr/bin/awk '{print $1}')
        [ "$actual" = \(shellQuote(digest)) ] || exit 74
        /usr/bin/codesign --verify --strict "$stage"
        /usr/sbin/chown root:wheel "$stage"
        /bin/chmod 755 "$stage"
        /bin/cat > "$plist_stage" <<'NEBULA_GUI_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>net.nebula.gui.helper</string>
          <key>ProgramArguments</key><array>
            <string>\(helperPath)</string><string>-uid</string><string>\(uid)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ExitTimeOut</key><integer>15</integer>
          <key>Umask</key><integer>18</integer>
        </dict></plist>
        NEBULA_GUI_PLIST
        /usr/sbin/chown root:wheel "$plist_stage"
        /bin/chmod 644 "$plist_stage"
        \(upgrading ? "published=1\n/bin/launchctl bootout --wait system/net.nebula.gui.helper" : "")
        /bin/mv "$stage" \(shellQuote(helperPath))
        published=1
        /bin/mv "$plist_stage" \(shellQuote(plistPath))
        /bin/launchctl bootstrap system \(shellQuote(plistPath))
        ready=0
        for attempt in 1 2 3 4 5; do
          if /usr/bin/sudo -u '#\(uid)' \(shellQuote(helperPath)) -health; then ready=1; break; fi
          /bin/sleep 0.2
        done
        [ "$ready" -eq 1 ] || exit 76
        committed=1
        """
        return AuthorizationPlan(script: script)
    }
    public static func uninstall() -> AuthorizationPlan {
        AuthorizationPlan(script: preflight + "\n" + """
        /bin/mkdir /Library/PrivilegedHelperTools/net.nebula.gui/.install-lock || exit 79
        trap '/bin/rmdir /Library/PrivilegedHelperTools/net.nebula.gui/.install-lock' EXIT
        /bin/launchctl bootout --wait system/net.nebula.gui.helper >/dev/null 2>&1 || {
          if /bin/launchctl print system/net.nebula.gui.helper >/dev/null 2>&1; then exit 75; fi
        }
        /bin/rm -f \(shellQuote(plistPath)) \(shellQuote(helperPath))

        """)
    }
    public var appleScript: String {
        let encoded = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(encoded)\" with administrator privileges"
    }
}
public struct AuthorizationState: Decodable, Sendable {
    public let available: Bool
    public let revision: String?
    public let reason: String?
    public let helperRelease: String?
    public var updateRequired: Bool? = nil
    public var supportsRecovery: Bool { available && updateRequired == false }
    public static let missing = AuthorizationState(available: false, revision: nil, reason: "not_installed", helperRelease: nil)
}
