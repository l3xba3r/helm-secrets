#!/usr/bin/env sh

set -euf

# helm secrets doctor
#
# Read-only health check of the local helm-secrets setup. It never reads,
# decrypts or prints secret material: key files are only tested for existence.
#
# Exit code: 0 when no check failed (warnings allowed), 1 otherwise.

_DOCTOR_FAILURES=0
_DOCTOR_WARNINGS=0

_doctor_ok() {
    printf '[ OK ] %s\n' "$*"
}

_doctor_info() {
    printf '[INFO] %s\n' "$*"
}

_doctor_warn() {
    _DOCTOR_WARNINGS=$((_DOCTOR_WARNINGS + 1))
    printf '[WARN] %s\n' "$*"
}

_doctor_fail() {
    _DOCTOR_FAILURES=$((_DOCTOR_FAILURES + 1))
    printf '[FAIL] %s\n' "$*"
}

_doctor_section() {
    printf '\n%s\n' "$*"
}

# Extract the first x.y.z version number from stdin.
_doctor_extract_version() {
    sed -n 's/[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
}

# Returns 0 if version $1 >= version $2 (numeric x.y.z comparison).
_doctor_version_ge() {
    awk -v a="${1}" -v b="${2}" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if ((x[i] + 0) > (y[i] + 0)) exit 0
            if ((x[i] + 0) < (y[i] + 0)) exit 1
        }
        exit 0
    }'
}

# Prints the version column of plugin $1 from 'helm plugin list', empty if absent.
_doctor_plugin_version() {
    printf '%s\n' "${_DOCTOR_PLUGIN_LIST}" | awk -v name="${1}" '$1 == name { print $2; exit }'
}

_doctor_check_helm() {
    _doctor_section "Helm"

    if ! helm_version_output="$("${HELM_BIN}" version --short 2>/dev/null)"; then
        _doctor_fail "helm binary '${HELM_BIN}' could not be executed (set HELM_SECRETS_HELM_PATH to override)"
        _DOCTOR_HELM_MAJOR=""
        return
    fi

    _DOCTOR_HELM_VERSION="$(printf '%s\n' "${helm_version_output}" | _doctor_extract_version)"
    _DOCTOR_HELM_MAJOR="${_DOCTOR_HELM_VERSION%%.*}"
    _doctor_ok "helm ${_DOCTOR_HELM_VERSION:-unknown} (${HELM_BIN})"

    if [ "${_DOCTOR_HELM_MAJOR}" = "3" ] && ! _doctor_version_ge "${_DOCTOR_HELM_VERSION}" "3.9.0"; then
        _doctor_warn "helm < 3.9.0: --evaluate-templates is not supported"
    fi
}

_doctor_check_plugins() {
    _doctor_section "helm-secrets plugins"

    own_version="$(version)"
    _doctor_ok "helm-secrets ${own_version}"

    if [ "${_DOCTOR_HELM_MAJOR}" = "" ]; then
        _doctor_info "skipped: helm is not available"
        return
    fi

    if ! _DOCTOR_PLUGIN_LIST="$("${HELM_BIN}" plugin list 2>/dev/null)"; then
        _doctor_warn "'helm plugin list' failed, plugin installation could not be verified"
        return
    fi

    if [ "${_DOCTOR_HELM_MAJOR}" -ge 4 ]; then
        # Helm 4 requires one plugin per type, see docs/Installation.md
        for plugin in secrets secrets-getter secrets-post-renderer; do
            plugin_version="$(_doctor_plugin_version "${plugin}")"

            if [ "${plugin_version}" = "" ]; then
                case "${plugin}" in
                secrets) hint="'helm secrets' commands are not available" ;;
                secrets-getter) hint="secrets:// value files will not work" ;;
                *) hint="--evaluate-templates will not work" ;;
                esac
                _doctor_fail "plugin '${plugin}' is not installed: ${hint}"
            elif [ "${plugin_version}" != "${own_version}" ]; then
                _doctor_warn "plugin '${plugin}' is ${plugin_version}, expected ${own_version} (install matching versions)"
            else
                _doctor_ok "plugin '${plugin}' ${plugin_version}"
            fi
        done
    else
        plugin_version="$(_doctor_plugin_version "secrets")"
        if [ "${plugin_version}" = "" ]; then
            _doctor_warn "plugin 'secrets' not found in 'helm plugin list'"
        else
            _doctor_ok "plugin 'secrets' ${plugin_version}"
        fi
    fi
}

_doctor_check_backend() {
    _doctor_section "Secret backend"

    case "${SECRET_BACKEND}" in
    sops)
        backend_bin="${_SOPS}"
        min_version="3.0.0"
        ;;
    vals)
        backend_bin="${_VALS}"
        min_version="0.20.0"
        ;;
    noop)
        _doctor_ok "backend 'noop' (no decryption)"
        return
        ;;
    *)
        _doctor_ok "custom backend '${DEFAULT_SECRET_BACKEND}'"
        return
        ;;
    esac

    _doctor_info "backend '${SECRET_BACKEND}'"

    if ! command -v "${backend_bin}" >/dev/null 2>&1; then
        _doctor_fail "${SECRET_BACKEND} binary '${backend_bin}' not found in PATH"
        return
    fi

    if [ "${SECRET_BACKEND}" = "sops" ]; then
        # --disable-version-check avoids a network call; older sops releases do not know the flag.
        backend_version="$("${backend_bin}" --version --disable-version-check 2>/dev/null | _doctor_extract_version)"
        if [ "${backend_version}" = "" ]; then
            backend_version="$("${backend_bin}" --version 2>/dev/null | _doctor_extract_version)"
        fi
    else
        backend_version="$("${backend_bin}" version 2>/dev/null | _doctor_extract_version)"
    fi

    if [ "${backend_version}" = "" ]; then
        _doctor_warn "${SECRET_BACKEND} found at '${backend_bin}', but its version could not be determined"
        return
    fi

    if ! _doctor_version_ge "${backend_version}" "${min_version}"; then
        _doctor_fail "${SECRET_BACKEND} ${backend_version} is too old, ${min_version} or newer is required"
        return
    fi

    _doctor_ok "${SECRET_BACKEND} ${backend_version} (${backend_bin})"

    if [ "${SECRET_BACKEND}" = "sops" ] && ! _doctor_version_ge "${backend_version}" "3.12.0"; then
        _doctor_info "sops < 3.12.0: post-quantum age recipients (age1pq1...) are not supported"
    fi
}

# Returns 0 if file $1 exists. On WSL and Cygwin, sops may be a Windows binary
# that receives Windows paths (C:\...), so those are converted before testing.
_doctor_file_exists() {
    if [ -f "${1}" ]; then
        return 0
    fi

    case "${1}" in
    [A-Za-z]:\\* | [A-Za-z]:/* | \\\\*)
        if on_wsl && command -v wslpath >/dev/null 2>&1; then
            [ -f "$(wslpath -u "${1}" 2>/dev/null)" ] && return 0
        elif on_cygwin; then
            [ -f "$(cygpath -u "${1}" 2>/dev/null)" ] && return 0
        fi
        ;;
    esac

    return 1
}

# Only tests whether key material is configured. Never reads it.
_doctor_check_keys() {
    [ "${SECRET_BACKEND}" = "sops" ] || return 0

    _doctor_section "Decryption keys (presence only, contents are never read)"

    found=false

    if [ -n "${SOPS_AGE_KEY:-}" ]; then
        _doctor_ok "age: SOPS_AGE_KEY is set"
        found=true
    fi

    if [ -n "${SOPS_AGE_KEY_CMD:-}" ]; then
        _doctor_ok "age: SOPS_AGE_KEY_CMD is set"
        found=true
    fi

    if [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
        if _doctor_file_exists "${SOPS_AGE_KEY_FILE}"; then
            _doctor_ok "age: SOPS_AGE_KEY_FILE points to an existing file"
            found=true
        else
            _doctor_fail "age: SOPS_AGE_KEY_FILE is set, but '${SOPS_AGE_KEY_FILE}' does not exist"
        fi
    else
        for age_keys in \
            "${XDG_CONFIG_HOME:-${HOME:-}/.config}/sops/age/keys.txt" \
            "${HOME:-}/Library/Application Support/sops/age/keys.txt"; do
            if [ -f "${age_keys}" ]; then
                _doctor_ok "age: key file found at '${age_keys}'"
                found=true
                break
            fi
        done
    fi

    if command -v "${SOPS_GPG_EXEC:-gpg}" >/dev/null 2>&1; then
        _doctor_ok "gpg: '${SOPS_GPG_EXEC:-gpg}' available"
        found=true
    fi

    if [ "${found}" = "false" ]; then
        _doctor_warn "no local age key or gpg found (fine if your .sops.yaml uses cloud KMS or Vault/OpenBao)"
    fi
}

_doctor_check_security() {
    _doctor_section "Security"

    if [ "${ALLOWED_BACKENDS}" != "" ]; then
        _doctor_ok "HELM_SECRETS_ALLOWED_BACKENDS=${ALLOWED_BACKENDS}"
    elif [ -n "${ARGOCD_APP_NAME+x}" ]; then
        _doctor_warn "HELM_SECRETS_ALLOWED_BACKENDS is not set inside Argo CD, recommended: sops,vals (see docs/Security in shared environments.md)"
    else
        _doctor_info "HELM_SECRETS_ALLOWED_BACKENDS is not set (recommended in shared environments such as Argo CD)"
    fi

    if command -v "${HELM_SECRETS_CURL_PATH:-curl}" >/dev/null 2>&1 || command -v "${HELM_SECRETS_WGET_PATH:-wget}" >/dev/null 2>&1; then
        _doctor_ok "curl or wget available for remote (http/https) value files"
    else
        _doctor_info "neither curl nor wget found: remote (http/https) value files will not work"
    fi
}

doctor() {
    printf 'helm-secrets doctor\n'

    _doctor_check_helm
    _doctor_check_plugins
    _doctor_check_backend
    _doctor_check_keys
    _doctor_check_security

    printf '\nSummary: %s failed, %s warning(s)\n' "${_DOCTOR_FAILURES}" "${_DOCTOR_WARNINGS}"

    [ "${_DOCTOR_FAILURES}" -eq 0 ]
}
