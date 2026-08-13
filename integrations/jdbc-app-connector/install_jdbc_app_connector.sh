#!/usr/bin/env bash
# =============================================================================
# install_jdbc_app_connector.sh
# One-command installer for the Generic JDBC Application -> Veza OAA integration.
# =============================================================================
set -euo pipefail

INTEGRATION_SUBDIR="integrations/jdbc-app-connector"
SCRIPT_NAME="jdbc_app_connector.py"
DEFAULT_BASE_DIR="/opt/VEZA/JDBC"
DEFAULT_DRIVERS_DIR="${DEFAULT_BASE_DIR}/drivers"
DEFAULT_BRANCH="main"
DEFAULT_REPO_URL="https://github.com/andrewmusto-git/JDBCAppConnector.git"
TOTAL_STEPS=10

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

_info() { echo "${CYAN}[i]${RESET} $*"; }
_ok() { echo "${GREEN}[ok]${RESET} $*"; }
_warn() { echo "${YELLOW}[warn]${RESET} $*"; }
_die() { echo "${RED}[fail]${RESET} $*" >&2; exit 1; }

_milestone() {
    local step=$1
    shift
    echo ""
    echo "${BOLD}------------------------------------------------------------${RESET}"
    printf "${BOLD}Step %d / %d - %s${RESET}\n" "${step}" "${TOTAL_STEPS}" "$*"
    echo "${BOLD}------------------------------------------------------------${RESET}"
}

_slugify() {
    local value="$1"
    value="${value// /-}"
    value=$(echo "${value}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')
    echo "${value}"
}

_pathify() {
    local value="$1"
    value="${value// /-}"
    echo "${value}"
}

_prompt() {
    local var_name=$1
    local prompt_text=$2
    local default_val=${3:-}

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return
    fi

    local display_default=""
    if [[ -n "${default_val}" ]]; then
        display_default=" [${default_val}]"
    fi

    local value
    IFS= read -r -p "${CYAN}?${RESET} ${prompt_text}${display_default}: " value </dev/tty
    if [[ -z "${value}" && -n "${default_val}" ]]; then
        value="${default_val}"
    fi
    printf -v "${var_name}" '%s' "${value}"
}

_prompt_secret() {
    local var_name=$1
    local prompt_text=$2

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        return
    fi

    local value
    IFS= read -r -s -p "${CYAN}?${RESET} ${prompt_text}: " value </dev/tty
    echo >/dev/tty
    printf -v "${var_name}" '%s' "${value}"
}

_require_var() {
    local name="$1"
    local value="$2"
    if [[ -z "${value}" ]]; then
        _die "Missing required value for ${name} in non-interactive mode"
    fi
}

_install_pkg() {
    local pkg="$1"
    _info "Installing ${pkg}"
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null ;;
        apt-get) apt-get install -y "${pkg}" >/dev/null ;;
    esac
}

_resolve_driver_metadata() {
    local type="$1"
    case "${type}" in
        mssql)
            JDBC_DRIVER_CLASS_DEFAULT="com.microsoft.sqlserver.jdbc.SQLServerDriver"
            JDBC_JAR_FILE="mssql-jdbc-12.8.1.jre11.jar"
            JDBC_COMPAT_GLOB="mssql-jdbc-*.jar"
            JDBC_URL="https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.8.1.jre11/mssql-jdbc-12.8.1.jre11.jar"
            JDBC_CLASS_CHECK="com/microsoft/sqlserver/jdbc/SQLServerDriver.class"
            ;;
        postgresql)
            JDBC_DRIVER_CLASS_DEFAULT="org.postgresql.Driver"
            JDBC_JAR_FILE="postgresql-42.7.4.jar"
            JDBC_COMPAT_GLOB="postgresql-*.jar"
            JDBC_URL="https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar"
            JDBC_CLASS_CHECK="org/postgresql/Driver.class"
            ;;
        mysql)
            JDBC_DRIVER_CLASS_DEFAULT="com.mysql.cj.jdbc.Driver"
            JDBC_JAR_FILE="mysql-connector-j-8.4.0.jar"
            JDBC_COMPAT_GLOB="mysql-connector-j-*.jar"
            JDBC_URL="https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.4.0/mysql-connector-j-8.4.0.jar"
            JDBC_CLASS_CHECK="com/mysql/cj/jdbc/Driver.class"
            ;;
        oracle)
            JDBC_DRIVER_CLASS_DEFAULT="oracle.jdbc.OracleDriver"
            JDBC_JAR_FILE="ojdbc11-23.4.0.24.05.jar"
            JDBC_COMPAT_GLOB="ojdbc11-*.jar"
            JDBC_URL="https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/23.4.0.24.05/ojdbc11-23.4.0.24.05.jar"
            JDBC_CLASS_CHECK="oracle/jdbc/OracleDriver.class"
            ;;
        *)
            _die "Unsupported DB_JDBC_DRIVER_TYPE '${type}'. Use mssql, postgresql, mysql, or oracle."
            ;;
    esac
}

_find_compatible_driver_jar() {
    local dir="$1"
    local pattern="$2"
    local class_check="$3"
    local candidate

    shopt -s nullglob
    for candidate in "${dir}"/${pattern}; do
        if jar tf "${candidate}" >/dev/null 2>&1 && jar tf "${candidate}" | grep -q "${class_check}"; then
            echo "${candidate}"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

NON_INTERACTIVE=false
OVERWRITE_ENV=false
INSTALL_DIR=""
DRIVERS_DIR="${DEFAULT_DRIVERS_DIR}"
BRANCH="${DEFAULT_BRANCH}"
REPO_URL="${DEFAULT_REPO_URL}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --overwrite-env) OVERWRITE_ENV=true ;;
        --install-dir) INSTALL_DIR="$2"; shift ;;
        --drivers-dir) DRIVERS_DIR="$2"; shift ;;
        --repo-url) REPO_URL="$2"; shift ;;
        --branch) BRANCH="$2"; shift ;;
        *) _warn "Unknown flag: $1" ;;
    esac
    shift
done

_milestone 1 "Detecting OS and package manager"

OS_ID=""
PKG_MGR=""
if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
fi

if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
else
    _die "No supported package manager found"
fi
_ok "OS=${OS_ID:-unknown} PKG_MGR=${PKG_MGR}"

_milestone 2 "Installing system prerequisites"

command -v git >/dev/null 2>&1 || _install_pkg git
command -v python3 >/dev/null 2>&1 || _install_pkg python3
python3 -m pip --version >/dev/null 2>&1 || _install_pkg python3-pip

if ! command -v curl >/dev/null 2>&1; then
    if [[ "${OS_ID}" == "amzn" ]]; then
        _warn "Skipping curl install on Amazon Linux due to curl-minimal"
    else
        _install_pkg curl
    fi
fi

if ! python3 -m venv --help >/dev/null 2>&1; then
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg python3-virtualenv ;;
        apt-get) _install_pkg python3-venv ;;
    esac
fi

if command -v java >/dev/null 2>&1 && command -v jar >/dev/null 2>&1; then
    _ok "Java runtime and jar tool are available"
else
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg java-17-openjdk-devel ;;
        apt-get) _install_pkg openjdk-17-jdk ;;
    esac
fi

command -v java >/dev/null 2>&1 || _die "Java runtime not found"
command -v jar >/dev/null 2>&1 || _die "jar tool not found"

_milestone 3 "Verifying Python version"

PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
if [[ "${PY_MAJOR}" -lt 3 || ( "${PY_MAJOR}" -eq 3 && "${PY_MINOR}" -lt 9 ) ]]; then
    _die "Python 3.9 or newer is required. Found ${PY_VER}."
fi
_ok "Python ${PY_VER}"

_milestone 4 "Collecting application identity and install path"

if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    APPLICATION_NAME="${APPLICATION_NAME:-}"
    _require_var "APPLICATION_NAME" "${APPLICATION_NAME}"
else
    _prompt APPLICATION_NAME "Application Name (spaces are converted to dashes in folder path)" "${APPLICATION_NAME:-JDBC Application}"
fi

APPLICATION_DIR_NAME=$(_pathify "${APPLICATION_NAME}")

if [[ -z "${INSTALL_DIR}" ]]; then
    INSTALL_DIR="${DEFAULT_BASE_DIR}/${APPLICATION_DIR_NAME}"
fi

SCRIPTS_DIR="${INSTALL_DIR}/scripts"
LOGS_DIR="${INSTALL_DIR}/logs"
VENV_DIR="${SCRIPTS_DIR}/venv"
ENV_FILE="${SCRIPTS_DIR}/.env"
DEFAULT_DATASOURCE_NAME="${APPLICATION_NAME}"
DEFAULT_PROVIDER_NAME="JDBC Applications"
APP_SLUG=$(_slugify "${APPLICATION_NAME}")
_ok "Install directory: ${INSTALL_DIR}"
_ok "Application folder name: ${APPLICATION_DIR_NAME}"
_ok "Shared JDBC drivers directory: ${DRIVERS_DIR}"

_milestone 5 "Cloning integration files"

TMP_DIR=$(mktemp -d)
GIT_TERMINAL_PROMPT=0 git clone --branch "${BRANCH}" --depth 1 --single-branch "${REPO_URL}" "${TMP_DIR}" \
    || _die "git clone failed for ${REPO_URL} branch ${BRANCH}"
_ok "Repository cloned"

_milestone 6 "Creating folder layout and copying integration files"

mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}" "${DRIVERS_DIR}"
cp -f "${TMP_DIR}/${INTEGRATION_SUBDIR}/${SCRIPT_NAME}" "${SCRIPTS_DIR}/"
cp -f "${TMP_DIR}/${INTEGRATION_SUBDIR}/requirements.txt" "${SCRIPTS_DIR}/"
cp -f "${TMP_DIR}/${INTEGRATION_SUBDIR}/.env.example" "${SCRIPTS_DIR}/"
rm -rf "${TMP_DIR}"
_ok "Files copied to ${SCRIPTS_DIR}"

_milestone 7 "Selecting, installing, and validating JDBC driver"

if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    DB_JDBC_DRIVER_TYPE="${DB_JDBC_DRIVER_TYPE:-mssql}"
else
    _prompt DB_JDBC_DRIVER_TYPE "JDBC driver type (mssql|postgresql|mysql|oracle)" "${DB_JDBC_DRIVER_TYPE:-mssql}"
fi

_resolve_driver_metadata "${DB_JDBC_DRIVER_TYPE}"
JDBC_JAR_PATH="${DRIVERS_DIR}/${JDBC_JAR_FILE}"

if existing_jar=$(_find_compatible_driver_jar "${DRIVERS_DIR}" "${JDBC_COMPAT_GLOB}" "${JDBC_CLASS_CHECK}"); then
    JDBC_JAR_PATH="${existing_jar}"
    _ok "Reusing compatible ${DB_JDBC_DRIVER_TYPE} driver jar: ${JDBC_JAR_PATH}"
else
    _info "No compatible ${DB_JDBC_DRIVER_TYPE} driver found in shared cache; downloading ${JDBC_JAR_FILE}"
    curl -fsSL "${JDBC_URL}" -o "${JDBC_JAR_PATH}" || _die "Failed to download JDBC jar"
fi

jar tf "${JDBC_JAR_PATH}" >/dev/null 2>&1 || _die "JDBC jar validation failed"
jar tf "${JDBC_JAR_PATH}" | grep -q "${JDBC_CLASS_CHECK}" \
    || _die "JDBC jar does not contain expected class ${JDBC_CLASS_CHECK}"
_ok "JDBC driver ready at ${JDBC_JAR_PATH}"

_milestone 8 "Creating virtual environment and installing Python dependencies"

if [[ -d "${VENV_DIR}" ]]; then
    _info "venv already exists"
else
    python3 -m venv "${VENV_DIR}" || _die "Failed to create venv"
fi

"${VENV_DIR}/bin/pip" install --upgrade pip --quiet
"${VENV_DIR}/bin/pip" install -r "${SCRIPTS_DIR}/requirements.txt" || _die "pip install failed"
_ok "Dependencies installed"

_milestone 9 "Collecting configuration and writing .env"

if [[ -f "${ENV_FILE}" && "${OVERWRITE_ENV}" != "true" ]]; then
    _info "Existing .env kept (use --overwrite-env to regenerate)"
else
    PROVIDER_NAME="${PROVIDER_NAME:-${DEFAULT_PROVIDER_NAME}}"
    DATASOURCE_NAME="${DATASOURCE_NAME:-${DEFAULT_DATASOURCE_NAME}}"

    _prompt PROVIDER_NAME "Provider name in Veza" "${PROVIDER_NAME}"
    _prompt DATASOURCE_NAME "Datasource name in Veza" "${DATASOURCE_NAME}"

    _prompt VEZA_URL "Veza tenant URL" "${VEZA_URL:-}"
    _prompt_secret VEZA_API_KEY "Veza API key"

    _prompt DB_SERVER "Database hostname or IP" "${DB_SERVER:-}"
    _prompt DB_PORT "Database port (optional)" "${DB_PORT:-}"
    _prompt DB_INSTANCE "Database named instance (blank if none)" "${DB_INSTANCE:-}"
    _prompt DB_NAME "Database name" "${DB_NAME:-}"
    _prompt DB_USER "Database username" "${DB_USER:-}"
    _prompt_secret DB_PASSWORD "Database password"
    _prompt DB_DOMAIN "AD domain for NTLM (blank to omit)" "${DB_DOMAIN:-}"

    _prompt DB_JDBC_URL "Full JDBC URL (blank to auto-build SQL Server URL)" "${DB_JDBC_URL:-}"
    _prompt DB_JDBC_DRIVER_CLASS "JDBC driver class" "${DB_JDBC_DRIVER_CLASS:-${JDBC_DRIVER_CLASS_DEFAULT}}"
    _prompt DB_JDBC_JAR "JDBC jar path" "${DB_JDBC_JAR:-${JDBC_JAR_PATH}}"

    _prompt JDBC_USERS_QUERY "Users query (must return user_id)" "${JDBC_USERS_QUERY:-SELECT user_id, full_name, email FROM users}"
    _prompt JDBC_ROLES_QUERY "Roles query (must return role_id)" "${JDBC_ROLES_QUERY:-SELECT role_id, role_name FROM roles}"
    _prompt JDBC_USER_ROLE_QUERY "User-role query (optional)" "${JDBC_USER_ROLE_QUERY:-SELECT user_id, role_id FROM user_role_map}"
    _prompt JDBC_GROUPS_QUERY "Groups query (optional)" "${JDBC_GROUPS_QUERY:-}"
    _prompt JDBC_USER_GROUP_QUERY "User-group query (optional)" "${JDBC_USER_GROUP_QUERY:-}"
    _prompt JDBC_ROLE_PERMISSION_QUERY "Role-permission query (optional)" "${JDBC_ROLE_PERMISSION_QUERY:-SELECT role_id, permission_name FROM role_permission_map}"
    _prompt JDBC_USER_PERMISSION_QUERY "User-permission query (optional)" "${JDBC_USER_PERMISSION_QUERY:-}"

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        _require_var "VEZA_URL" "${VEZA_URL:-}"
        _require_var "VEZA_API_KEY" "${VEZA_API_KEY:-}"
        _require_var "DB_USER" "${DB_USER:-}"
        _require_var "DB_PASSWORD" "${DB_PASSWORD:-}"
        _require_var "JDBC_USERS_QUERY" "${JDBC_USERS_QUERY:-}"
        _require_var "JDBC_ROLES_QUERY" "${JDBC_ROLES_QUERY:-}"
    fi

    DB_JDBC_JAR="${DB_JDBC_JAR:-${JDBC_JAR_PATH}}"

    cat > "${ENV_FILE}" <<EOF
# Generic JDBC Application -> Veza OAA Integration
# Generated by install_jdbc_app_connector.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

APPLICATION_NAME=${APPLICATION_NAME}
PROVIDER_NAME=${PROVIDER_NAME}
DATASOURCE_NAME=${DATASOURCE_NAME}

VEZA_URL=${VEZA_URL}
VEZA_API_KEY=${VEZA_API_KEY}

DB_SERVER=${DB_SERVER}
DB_PORT=${DB_PORT}
DB_INSTANCE=${DB_INSTANCE}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_DOMAIN=${DB_DOMAIN}
DB_JDBC_URL=${DB_JDBC_URL}
DB_JDBC_DRIVER_TYPE=${DB_JDBC_DRIVER_TYPE}
DB_JDBC_DRIVER_CLASS=${DB_JDBC_DRIVER_CLASS}
DB_JDBC_JAR=${DB_JDBC_JAR}

JDBC_USERS_QUERY=${JDBC_USERS_QUERY}
JDBC_ROLES_QUERY=${JDBC_ROLES_QUERY}
JDBC_GROUPS_QUERY=${JDBC_GROUPS_QUERY}
JDBC_USER_ROLE_QUERY=${JDBC_USER_ROLE_QUERY}
JDBC_USER_GROUP_QUERY=${JDBC_USER_GROUP_QUERY}
JDBC_ROLE_PERMISSION_QUERY=${JDBC_ROLE_PERMISSION_QUERY}
JDBC_USER_PERMISSION_QUERY=${JDBC_USER_PERMISSION_QUERY}

USERS_COL_ID=user_id
USERS_COL_FULL_NAME=full_name
USERS_COL_EMAIL=email
USERS_COL_ROLE_ID=role_id
USERS_COL_GROUP_ID=group_id
ROLES_COL_ID=role_id
ROLES_COL_NAME=role_name
GROUPS_COL_ID=group_id
GROUPS_COL_NAME=group_name
USER_ROLE_COL_USER_ID=user_id
USER_ROLE_COL_ROLE_ID=role_id
USER_GROUP_COL_USER_ID=user_id
USER_GROUP_COL_GROUP_ID=group_id
ROLE_PERMISSION_COL_ROLE_ID=role_id
ROLE_PERMISSION_COL_PERMISSION=permission_name
USER_PERMISSION_COL_USER_ID=user_id
USER_PERMISSION_COL_PERMISSION=permission_name
CUSTOM_PERMISSIONS=read,write,admin
EOF

    chmod 600 "${ENV_FILE}"
    _ok ".env generated at ${ENV_FILE}"
fi

_milestone 10 "Finalizing"

chmod +x "${SCRIPTS_DIR}/${SCRIPT_NAME}"
"${VENV_DIR}/bin/python3" "${SCRIPTS_DIR}/${SCRIPT_NAME}" --help >/dev/null 2>&1 || _warn "--help smoke test failed"

_ok "Installation complete"
echo ""
echo "Install path : ${INSTALL_DIR}"
echo "Script       : ${SCRIPTS_DIR}/${SCRIPT_NAME}"
echo "Config file  : ${ENV_FILE}"
echo "Drivers path : ${DRIVERS_DIR}"
echo "JDBC jar     : ${JDBC_JAR_PATH}"
echo ""
echo "Next steps:"
echo "  1) Review ${ENV_FILE}"
echo "  2) Run connector:"
echo "     cd ${SCRIPTS_DIR}"
echo "     ${VENV_DIR}/bin/python3 ${SCRIPT_NAME} --env-file .env --save-json --log-level DEBUG"
echo ""
echo "Application slug: ${APP_SLUG}"
