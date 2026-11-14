#!/usr/bin/env bash
#
# Installs AWS Emulator on a Linux GitHub Actions runner, starts it in the
# background, waits until it reports healthy, and (optionally) exports the
# environment variables that point the AWS CLI and SDKs at it.
#
# Inputs are passed as INPUT_* environment variables by action.yml.

set -euo pipefail

readonly PACKAGE_BASE_URL="https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS"
readonly SIGNING_KEY_URL="https://downloads.aws.com/keys/gpg/current.asc"
# AWS publishing key fingerprint, as documented in the AWS Emulator User Guide.
readonly SIGNING_KEY_FINGERPRINT="98BCF336A3BE53B734E967C52E5BF49BD940F624"
readonly EMULATOR_ACCOUNT_ID="000000000000"
readonly EMULATOR_REGION="us-east-1"

VERSION="${INPUT_VERSION:-latest}"
PORT="${INPUT_PORT:-9297}"
TELEMETRY="${INPUT_TELEMETRY:-off}"
AUTH="${INPUT_AUTH:-on}"
EXPORT_ENV="${INPUT_EXPORT_ENV:-true}"
VERIFY_SIGNATURE="${INPUT_VERIFY_SIGNATURE:-true}"
IDLE_TIMEOUT="${INPUT_IDLE_TIMEOUT:-}"
STARTUP_TIMEOUT="${INPUT_STARTUP_TIMEOUT:-60}"

WORK_DIR="${RUNNER_TEMP:-/tmp}/setup-aws-emulator"
LOG_FILE="${WORK_DIR}/emulator.log"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_ENV="${GITHUB_ENV:-/dev/null}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "$*"; }
warn() { echo "::warning title=setup-aws-emulator::$*"; }
fail() {
  echo "::error title=setup-aws-emulator::$*"
  exit 1
}
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

set_output() { echo "$1=$2" >>"${GITHUB_OUTPUT}"; }
set_env() { echo "$1=$2" >>"${GITHUB_ENV}"; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Run a command as root, using sudo when the current user is not root.
as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "Installing the package requires root privileges, and sudo is not available."
  fi
}

# Print the string value of a JSON key from a single line of JSON.
json_field() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$2" | head -n 1
}

# Print the value of a key from an INI-style AWS shared credentials file.
ini_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$2" | head -n 1
}

download() {
  curl --fail --silent --show-error --location \
    --retry 5 --retry-delay 2 --retry-connrefused \
    --output "$2" "$1"
}

# ---------------------------------------------------------------------------
# Validate inputs and platform
# ---------------------------------------------------------------------------

validate_inputs() {
  TELEMETRY="$(lower "${TELEMETRY}")"
  AUTH="$(lower "${AUTH}")"
  EXPORT_ENV="$(lower "${EXPORT_ENV}")"
  VERIFY_SIGNATURE="$(lower "${VERIFY_SIGNATURE}")"

  [[ "${TELEMETRY}" == "on" || "${TELEMETRY}" == "off" ]] ||
    fail "Input 'telemetry' must be 'on' or 'off' (got '${TELEMETRY}')."
  [[ "${AUTH}" == "on" || "${AUTH}" == "off" ]] ||
    fail "Input 'auth' must be 'on' or 'off' (got '${AUTH}')."
  [[ "${EXPORT_ENV}" == "true" || "${EXPORT_ENV}" == "false" ]] ||
    fail "Input 'export-env' must be 'true' or 'false' (got '${EXPORT_ENV}')."
  [[ "${VERIFY_SIGNATURE}" == "true" || "${VERIFY_SIGNATURE}" == "false" ]] ||
    fail "Input 'verify-signature' must be 'true' or 'false' (got '${VERIFY_SIGNATURE}')."

  if ! is_uint "${PORT}" || ((10#${PORT} > 65535)); then
    fail "Input 'port' must be an integer from 0 to 65535 (got '${PORT}')."
  fi
  PORT=$((10#${PORT}))

  if [[ -n "${IDLE_TIMEOUT}" ]]; then
    if ! is_uint "${IDLE_TIMEOUT}" || ((10#${IDLE_TIMEOUT} < 1 || 10#${IDLE_TIMEOUT} > 31536000)); then
      fail "Input 'idle-timeout' must be empty or an integer from 1 to 31536000 (got '${IDLE_TIMEOUT}')."
    fi
  fi

  if ! is_uint "${STARTUP_TIMEOUT}" || ((10#${STARTUP_TIMEOUT} < 1)); then
    fail "Input 'startup-timeout' must be a positive integer (got '${STARTUP_TIMEOUT}')."
  fi
}

detect_platform() {
  local os="${RUNNER_OS:-$(uname -s)}"
  if [[ "${os}" != "Linux" ]]; then
    fail "AWS Emulator runs natively only on Linux, and this runner is ${os}. Use a Linux runner such as 'ubuntu-latest' or 'ubuntu-24.04-arm'."
  fi

  local arch="${RUNNER_ARCH:-$(uname -m)}"
  case "${arch}" in
  X64 | x86_64 | amd64) DEB_ARCH="amd64" RPM_ARCH="x86_64" ;;
  ARM64 | aarch64 | arm64) DEB_ARCH="arm64" RPM_ARCH="aarch64" ;;
  *) fail "Unsupported runner architecture '${arch}'. AWS Emulator supports x86_64 and arm64." ;;
  esac

  if command -v dpkg >/dev/null 2>&1; then
    PACKAGE_FORMAT="deb"
  elif command -v rpm >/dev/null 2>&1; then
    PACKAGE_FORMAT="rpm"
  else
    fail "Neither dpkg nor rpm was found. AWS Emulator is distributed as Debian and RPM packages."
  fi

  command -v curl >/dev/null 2>&1 || fail "curl is required but was not found on the runner."
}

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------

# Sets VERSION (X.Y.Z) and PACKAGE_RELEASE (the package release number).
resolve_version() {
  local requested="${VERSION#v}"

  if [[ "$(lower "${requested}")" == "latest" ]]; then
    local versions_json
    if versions_json="$(curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
      "${PACKAGE_BASE_URL}/versions.json")"; then
      requested="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+(\.[0-9]+)+"' <<<"${versions_json}" |
        grep -oE '[0-9]+(\.[0-9]+)+' | sort -V | tail -n 1)"
    fi
    [[ -n "${requested}" ]] || fail "Could not determine the latest AWS Emulator version from ${PACKAGE_BASE_URL}/versions.json."
  fi

  # Accept X.Y.Z, X.Y.Z.R (as listed in versions.json), or X.Y.Z-R (package version).
  if [[ "${requested}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)([.-]([0-9]+))?$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
    PACKAGE_RELEASE="${BASH_REMATCH[3]:-1}"
  else
    fail "Input 'version' must be 'latest' or a version such as '1.0.367' (got '${INPUT_VERSION:-}')."
  fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

installed_version() {
  command -v aws-emulator >/dev/null 2>&1 || return 0
  aws-emulator --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

verify_signature() {
  local package_file="$1" signature_file="$2"

  command -v gpg >/dev/null 2>&1 ||
    fail "gpg is required to verify the package signature. Install gnupg or set 'verify-signature: false'."

  local gnupg_home
  gnupg_home="$(mktemp -d)"
  chmod 700 "${gnupg_home}"

  download "${SIGNING_KEY_URL}" "${WORK_DIR}/aws-publishing.asc"
  gpg --homedir "${gnupg_home}" --batch --quiet --import "${WORK_DIR}/aws-publishing.asc" 2>/dev/null

  # The signature must be valid and made by the pinned AWS publishing key. The
  # last field of VALIDSIG is the primary key fingerprint, which also covers
  # signatures made with a subkey.
  local status
  status="$(gpg --homedir "${gnupg_home}" --batch --status-fd 1 --verify "${signature_file}" "${package_file}" 2>/dev/null || true)"
  rm -rf "${gnupg_home}"

  if ! grep -qE "^\[GNUPG:\] VALIDSIG .* ${SIGNING_KEY_FINGERPRINT}\$" <<<"${status}"; then
    fail "GPG signature verification failed for $(basename "${package_file}"). The package was not installed."
  fi
  log "Signature verified (key ${SIGNING_KEY_FINGERPRINT})."
}

install_emulator() {
  local current
  current="$(installed_version)"
  if [[ -n "${current}" && "${current}" == "${VERSION}" ]]; then
    log "AWS Emulator ${VERSION} is already installed."
    return 0
  fi

  local package_file
  if [[ "${PACKAGE_FORMAT}" == "deb" ]]; then
    package_file="aws-emulator_${VERSION}-${PACKAGE_RELEASE}_${DEB_ARCH}.deb"
  else
    package_file="aws-emulator-${VERSION}-${PACKAGE_RELEASE}-${RPM_ARCH}.rpm"
  fi
  local package_path="${WORK_DIR}/${package_file}"

  log "Downloading ${PACKAGE_BASE_URL}/${package_file}"
  download "${PACKAGE_BASE_URL}/${package_file}" "${package_path}" ||
    fail "Could not download AWS Emulator ${VERSION}. Check that the version exists at ${PACKAGE_BASE_URL}/versions.json."

  if [[ "${VERIFY_SIGNATURE}" == "true" ]]; then
    download "${PACKAGE_BASE_URL}/${package_file}.sig" "${package_path}.sig" ||
      fail "Could not download the signature file ${package_file}.sig."
    verify_signature "${package_path}" "${package_path}.sig"
  fi

  log "Installing ${package_file}"
  if [[ "${PACKAGE_FORMAT}" == "deb" ]]; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
      -o DPkg::Lock::Timeout=120 --allow-downgrades "${package_path}"
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y "${package_path}"
  elif command -v yum >/dev/null 2>&1; then
    as_root yum install -y "${package_path}"
  else
    as_root rpm -U --replacepkgs --oldpackage "${package_path}"
  fi

  rm -f "${package_path}" "${package_path}.sig"
}

# ---------------------------------------------------------------------------
# Start and wait for readiness
# ---------------------------------------------------------------------------

dump_log() {
  if [[ -s "${LOG_FILE}" ]]; then
    echo "::group::Emulator log (${LOG_FILE})"
    cat "${LOG_FILE}"
    echo "::endgroup::"
  fi
}

start_emulator() {
  local args=(--port "${PORT}" --telemetry "${TELEMETRY}" --auth "${AUTH}")
  [[ -n "${IDLE_TIMEOUT}" ]] && args+=(--idle-timeout "${IDLE_TIMEOUT}")

  log "Starting: aws-emulator ${args[*]}"
  # Run detached from this step so the emulator keeps serving later steps in
  # the job. The runner stops it when the job finishes.
  EMULATOR_TELEMETRY="${TELEMETRY}" nohup aws-emulator "${args[@]}" >"${LOG_FILE}" 2>&1 </dev/null &
  EMULATOR_PID=$!
  disown "${EMULATOR_PID}" 2>/dev/null || true
}

wait_for_emulator() {
  local deadline=$((SECONDS + 10#${STARTUP_TIMEOUT}))
  local startup_line=""

  # 1. Wait for the startup line, which reports the endpoint and file paths.
  while [[ -z "${startup_line}" ]]; do
    if ! kill -0 "${EMULATOR_PID}" 2>/dev/null; then
      dump_log
      fail "AWS Emulator exited during startup. See the emulator log above."
    fi
    if ((SECONDS >= deadline)); then
      dump_log
      fail "AWS Emulator did not start within ${STARTUP_TIMEOUT} seconds."
    fi
    startup_line="$(grep -m 1 '"emulator server information"' "${LOG_FILE}" 2>/dev/null || true)"
    [[ -n "${startup_line}" ]] || sleep 0.5
  done

  ENDPOINT_URL="$(json_field endpoint_url "${startup_line}")"
  HEALTH_CHECK_URL="$(json_field health_check_url "${startup_line}")"
  CA_FILE="$(json_field ca_file "${startup_line}")"
  TRUSTSTORE_FILE="$(json_field java_truststore_file "${startup_line}")"

  # Fall back to the documented defaults if the startup line format changes.
  local actual_port="${ENDPOINT_URL##*:}"
  actual_port="${actual_port%%/*}"
  is_uint "${actual_port}" || actual_port="${PORT}"
  local state_dir="${HOME}/.aws/emulator/${actual_port}"
  ENDPOINT_URL="${ENDPOINT_URL:-https://127.0.0.1:${actual_port}}"
  HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-${ENDPOINT_URL}/__admin/health}"
  CA_FILE="${CA_FILE:-${state_dir}/ca.pem}"
  TRUSTSTORE_FILE="${TRUSTSTORE_FILE:-${state_dir}/truststore.p12}"

  state_dir="$(dirname "${CA_FILE}")"
  CONFIG_FILE="${state_dir}/config"
  CREDENTIALS_FILE="${state_dir}/emulator_credentials"

  # 2. Wait for the health route to return 200.
  until curl --silent --fail --max-time 5 --cacert "${CA_FILE}" "${HEALTH_CHECK_URL}" >/dev/null 2>&1; do
    if ! kill -0 "${EMULATOR_PID}" 2>/dev/null; then
      dump_log
      fail "AWS Emulator exited before it became healthy. See the emulator log above."
    fi
    if ((SECONDS >= deadline)); then
      dump_log
      fail "AWS Emulator did not report healthy at ${HEALTH_CHECK_URL} within ${STARTUP_TIMEOUT} seconds."
    fi
    sleep 0.5
  done

  # 3. With auth on, wait for the generated credentials file.
  if [[ "${AUTH}" == "on" ]]; then
    until [[ -s "${CREDENTIALS_FILE}" ]]; do
      if ((SECONDS >= deadline)); then
        dump_log
        fail "AWS Emulator did not write its credentials file (${CREDENTIALS_FILE}) within ${STARTUP_TIMEOUT} seconds."
      fi
      sleep 0.5
    done
  else
    CREDENTIALS_FILE=""
  fi
}

# ---------------------------------------------------------------------------
# Outputs and environment
# ---------------------------------------------------------------------------

write_outputs() {
  set_output version "${VERSION}"
  set_output endpoint-url "${ENDPOINT_URL}"
  set_output health-check-url "${HEALTH_CHECK_URL}"
  set_output ca-file "${CA_FILE}"
  set_output truststore-file "${TRUSTSTORE_FILE}"
  set_output credentials-file "${CREDENTIALS_FILE}"
  set_output config-file "${CONFIG_FILE}"
  set_output region "${EMULATOR_REGION}"
  set_output account-id "${EMULATOR_ACCOUNT_ID}"
  set_output pid "${EMULATOR_PID}"
  set_output log-file "${LOG_FILE}"
}

export_environment() {
  local access_key_id secret_access_key

  if [[ -n "${CREDENTIALS_FILE}" ]]; then
    access_key_id="$(ini_value aws_access_key_id "${CREDENTIALS_FILE}")"
    secret_access_key="$(ini_value aws_secret_access_key "${CREDENTIALS_FILE}")"
    [[ -n "${access_key_id}" && -n "${secret_access_key}" ]] ||
      fail "Could not read the emulator credentials from ${CREDENTIALS_FILE}."
    set_env AWS_SHARED_CREDENTIALS_FILE "${CREDENTIALS_FILE}"
  else
    # With auth off the emulator accepts any credentials, but SDKs still need
    # some to sign requests.
    access_key_id="EMULATORAUTHOFF00000"
    secret_access_key="emulator-auth-off"
  fi

  echo "::add-mask::${secret_access_key}"

  # Exporting credentials as environment variables makes them take precedence
  # over any profile or credentials configured earlier in the job, so no
  # request is signed with real AWS credentials.
  set_env AWS_ACCESS_KEY_ID "${access_key_id}"
  set_env AWS_SECRET_ACCESS_KEY "${secret_access_key}"
  if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
    warn "Clearing AWS_SESSION_TOKEN so requests are signed with the emulator credentials."
    set_env AWS_SESSION_TOKEN ""
  fi
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    warn "Setting AWS_PROFILE to 'default' so the emulator's AWS config is used."
    set_env AWS_PROFILE "default"
  fi

  [[ -f "${CONFIG_FILE}" ]] && set_env AWS_CONFIG_FILE "${CONFIG_FILE}"
  set_env AWS_ENDPOINT_URL "${ENDPOINT_URL}"
  set_env AWS_CA_BUNDLE "${CA_FILE}"
  set_env NODE_EXTRA_CA_CERTS "${CA_FILE}"
  set_env AWS_REGION "${EMULATOR_REGION}"
  set_env AWS_DEFAULT_REGION "${EMULATOR_REGION}"
  set_env AWS_EC2_METADATA_DISABLED "true"
  set_env AWS_DISABLE_HOST_PREFIX_INJECTION "true"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  validate_inputs
  detect_platform
  mkdir -p "${WORK_DIR}"

  group "Install AWS Emulator"
  resolve_version
  log "Requested version: ${INPUT_VERSION:-latest} (resolved to ${VERSION})"
  install_emulator
  aws-emulator --version || true
  endgroup

  group "Start AWS Emulator"
  start_emulator
  wait_for_emulator
  write_outputs
  [[ "${EXPORT_ENV}" == "true" ]] && export_environment
  log "AWS Emulator ${VERSION} is ready at ${ENDPOINT_URL} (pid ${EMULATOR_PID})."
  endgroup
}

main "$@"
