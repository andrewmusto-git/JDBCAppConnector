#!/usr/bin/env python3
"""
Generic JDBC Application -> Veza OAA Integration

This connector is reusable across multiple JDBC-backed applications. It reads
identity and authorization records through user-provided SQL queries and maps
those records to Veza OAA CustomApplication entities.
"""

import argparse
import json
import logging
import os
import sys
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler
from typing import Any

import jaydebeapi
from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission

log = logging.getLogger(__name__)

DEFAULT_DRIVER_DIR = "/opt/VEZA/JDBC/drivers"


def _default_driver_jar(driver_type: str) -> str:
    normalized = (driver_type or "mssql").strip().lower()
    mapping = {
        "mssql": "mssql-jdbc-12.8.1.jre11.jar",
        "postgresql": "postgresql-42.7.4.jar",
        "mysql": "mysql-connector-j-8.4.0.jar",
        "oracle": "ojdbc11-23.4.0.24.05.jar",
        "as400": "jt400-21.0.0.jar",
    }
    return os.path.join(DEFAULT_DRIVER_DIR, mapping.get(normalized, mapping["mssql"]))


def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generic JDBC Application -> Veza OAA integration",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    parser.add_argument("--data-dir", default="./samples", help="Data directory placeholder for compatibility")
    parser.add_argument("--env-file", default=".env", help="Path to .env credentials file")
    parser.add_argument("--veza-url", help="Veza tenant URL (overrides VEZA_URL env var)")
    parser.add_argument("--veza-api-key", help="Veza API key (overrides VEZA_API_KEY env var)")
    parser.add_argument("--provider-name", help="Provider name displayed in Veza")
    parser.add_argument("--datasource-name", help="Datasource name displayed in Veza")
    parser.add_argument("--application-name", help="Application name represented by this run")
    parser.add_argument("--save-json", action="store_true", help="Write payload to payload.json")
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity",
    )

    parser.add_argument("--db-server", help="Database host (overrides DB_SERVER env var)")
    parser.add_argument("--db-port", help="Database port (overrides DB_PORT env var)")
    parser.add_argument("--db-instance", help="Named DB instance (overrides DB_INSTANCE env var)")
    parser.add_argument("--db-name", help="Database name (overrides DB_NAME env var)")
    parser.add_argument("--db-user", help="Database login username (overrides DB_USER env var)")
    parser.add_argument("--db-password", help="Database login password (overrides DB_PASSWORD env var)")
    parser.add_argument("--db-domain", help="Windows domain for NTLM auth (overrides DB_DOMAIN env var)")
    parser.add_argument("--db-jdbc-url", help="Full JDBC URL (overrides DB_JDBC_URL env var)")
    parser.add_argument(
        "--db-jdbc-driver-class",
        help="JDBC driver class (overrides DB_JDBC_DRIVER_CLASS env var)",
    )
    parser.add_argument(
        "--db-jdbc-driver-type",
        choices=["mssql", "postgresql", "mysql", "oracle", "as400"],
        help="JDBC driver type (overrides DB_JDBC_DRIVER_TYPE env var). Use 'as400' for IBM iSeries/AS400 with JTOpen (jt400).",
    )
    parser.add_argument("--db-jdbc-jar", help="Path to JDBC jar (overrides DB_JDBC_JAR env var)")

    return parser.parse_args()


def load_config(args: argparse.Namespace) -> dict[str, Any]:
    if args.env_file and os.path.exists(args.env_file):
        load_dotenv(args.env_file)

    app_name = args.application_name or os.getenv("APPLICATION_NAME") or "JDBC Application"
    provider_name = args.provider_name or os.getenv("PROVIDER_NAME") or "JDBC Applications"
    datasource_name = args.datasource_name or os.getenv("DATASOURCE_NAME") or app_name
    driver_type = args.db_jdbc_driver_type or os.getenv("DB_JDBC_DRIVER_TYPE", "mssql")

    config: dict[str, Any] = {
        "application_name": app_name,
        "provider_name": provider_name,
        "datasource_name": datasource_name,
        "veza_url": args.veza_url or os.getenv("VEZA_URL"),
        "veza_api_key": args.veza_api_key or os.getenv("VEZA_API_KEY"),
        "db_server": args.db_server or os.getenv("DB_SERVER"),
        "db_port": args.db_port or os.getenv("DB_PORT", ""),
        "db_instance": args.db_instance or os.getenv("DB_INSTANCE", ""),
        "db_name": args.db_name or os.getenv("DB_NAME"),
        "db_user": args.db_user or os.getenv("DB_USER"),
        "db_password": args.db_password or os.getenv("DB_PASSWORD"),
        "db_domain": args.db_domain or os.getenv("DB_DOMAIN", ""),
        "db_jdbc_url": args.db_jdbc_url or os.getenv("DB_JDBC_URL", ""),
        "db_jdbc_driver_class": (
            args.db_jdbc_driver_class
            or os.getenv("DB_JDBC_DRIVER_CLASS")
            or "com.microsoft.sqlserver.jdbc.SQLServerDriver"
        ),
        "db_jdbc_driver_type": driver_type,
        "db_jdbc_jar": args.db_jdbc_jar or os.getenv("DB_JDBC_JAR") or _default_driver_jar(driver_type),
        "queries": {
            "users": os.getenv("JDBC_USERS_QUERY", "").strip(),
            "roles": os.getenv("JDBC_ROLES_QUERY", "").strip(),
            "groups": os.getenv("JDBC_GROUPS_QUERY", "").strip(),
            "user_role": os.getenv("JDBC_USER_ROLE_QUERY", "").strip(),
            "user_group": os.getenv("JDBC_USER_GROUP_QUERY", "").strip(),
            "role_permission": os.getenv("JDBC_ROLE_PERMISSION_QUERY", "").strip(),
            "user_permission": os.getenv("JDBC_USER_PERMISSION_QUERY", "").strip(),
        },
        "columns": {
            "users_col_id": os.getenv("USERS_COL_ID", "user_id"),
            "users_col_full_name": os.getenv("USERS_COL_FULL_NAME", "full_name"),
            "users_col_email": os.getenv("USERS_COL_EMAIL", "email"),
            "users_col_role_id": os.getenv("USERS_COL_ROLE_ID", "role_id"),
            "users_col_group_id": os.getenv("USERS_COL_GROUP_ID", "group_id"),
            "roles_col_id": os.getenv("ROLES_COL_ID", "role_id"),
            "roles_col_name": os.getenv("ROLES_COL_NAME", "role_name"),
            "groups_col_id": os.getenv("GROUPS_COL_ID", "group_id"),
            "groups_col_name": os.getenv("GROUPS_COL_NAME", "group_name"),
            "user_role_col_user_id": os.getenv("USER_ROLE_COL_USER_ID", "user_id"),
            "user_role_col_role_id": os.getenv("USER_ROLE_COL_ROLE_ID", "role_id"),
            "user_group_col_user_id": os.getenv("USER_GROUP_COL_USER_ID", "user_id"),
            "user_group_col_group_id": os.getenv("USER_GROUP_COL_GROUP_ID", "group_id"),
            "role_permission_col_role_id": os.getenv("ROLE_PERMISSION_COL_ROLE_ID", "role_id"),
            "role_permission_col_permission": os.getenv("ROLE_PERMISSION_COL_PERMISSION", "permission_name"),
            "user_permission_col_user_id": os.getenv("USER_PERMISSION_COL_USER_ID", "user_id"),
            "user_permission_col_permission": os.getenv("USER_PERMISSION_COL_PERMISSION", "permission_name"),
        },
        "custom_permissions": [
            x.strip().lower()
            for x in os.getenv("CUSTOM_PERMISSIONS", "read,write,admin").split(",")
            if x.strip()
        ],
    }

    missing: list[str] = []
    if not config["veza_url"]:
        missing.append("VEZA_URL")
    if not config["veza_api_key"]:
        missing.append("VEZA_API_KEY")

    if not config["queries"]["users"]:
        missing.append("JDBC_USERS_QUERY")
    if not config["queries"]["roles"]:
        missing.append("JDBC_ROLES_QUERY")

    if not config["db_jdbc_jar"]:
        missing.append("DB_JDBC_JAR")

    if not config["db_jdbc_url"] and not config["db_server"]:
        missing.append("DB_SERVER or DB_JDBC_URL")

    if not config["db_user"]:
        missing.append("DB_USER")
    if not config["db_password"]:
        missing.append("DB_PASSWORD")

    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        sys.exit(1)

    if not os.path.exists(config["db_jdbc_jar"]):
        log.error("JDBC jar not found at %s", config["db_jdbc_jar"])
        sys.exit(1)

    return config


def _build_jdbc_url(config: dict[str, Any]) -> str:
    if config["db_jdbc_url"]:
        return config["db_jdbc_url"]

    driver_type = str(config.get("db_jdbc_driver_type", "mssql")).strip().lower()
    server = config["db_server"]
    port = config["db_port"]
    instance = config["db_instance"]
    db_name = config["db_name"]

    host_port = server
    if port:
        host_port = f"{server}:{port}"

    if driver_type == "mssql":
        url = f"jdbc:sqlserver://{host_port}"
        if instance:
            url += f";instanceName={instance}"
        if db_name:
            url += f";databaseName={db_name}"
        url += ";encrypt=true;trustServerCertificate=true"
        return url

    if driver_type == "postgresql":
        if db_name:
            return f"jdbc:postgresql://{host_port}/{db_name}"
        return f"jdbc:postgresql://{host_port}"

    if driver_type == "mysql":
        if db_name:
            return f"jdbc:mysql://{host_port}/{db_name}"
        return f"jdbc:mysql://{host_port}"

    if driver_type == "oracle":
        if db_name:
            return f"jdbc:oracle:thin:@//{host_port}/{db_name}"
        return f"jdbc:oracle:thin:@{host_port}"

    if driver_type == "as400":
        # Use SQL naming by default so schemas/libraries can be referenced as LIBRARY.TABLE.
        if db_name:
            return f"jdbc:as400://{host_port}/{db_name};naming=sql;errors=full"
        return f"jdbc:as400://{host_port};naming=sql;errors=full"

    log.warning("Unknown DB_JDBC_DRIVER_TYPE '%s'; defaulting JDBC URL builder to SQL Server", driver_type)
    url = f"jdbc:sqlserver://{host_port}"
    if instance:
        url += f";instanceName={instance}"
    if db_name:
        url += f";databaseName={db_name}"
    url += ";encrypt=true;trustServerCertificate=true"
    return url


def get_db_connection(config: dict[str, Any]):
    jdbc_url = _build_jdbc_url(config)
    args: dict[str, str] = {
        "user": config["db_user"],
        "password": config["db_password"],
    }

    if config["db_domain"]:
        args["domain"] = config["db_domain"]
        args["integratedSecurity"] = "true"
        args["authenticationScheme"] = "NTLM"

    try:
        conn = jaydebeapi.connect(
            jclassname=config["db_jdbc_driver_class"],
            url=jdbc_url,
            driver_args=args,
            jars=[config["db_jdbc_jar"]],
        )
        log.info("Connected to database using JDBC driver %s", config["db_jdbc_driver_class"])
        return conn
    except Exception as exc:
        log.error("Database connection failed: %s", exc)
        sys.exit(1)


def execute_query(conn, query: str) -> list[dict[str, Any]]:
    cursor = conn.cursor()
    cursor.execute(query)
    names = [str(c[0]).strip() for c in cursor.description]
    rows = []
    for row in cursor.fetchall():
        rows.append({names[i]: row[i] for i in range(len(names))})
    return rows


def _get_value(row: dict[str, Any], key_name: str) -> str:
    for key, value in row.items():
        if str(key).strip().lower() == key_name.strip().lower():
            if value is None:
                return ""
            return str(value).strip()
    return ""


def _perm_actions(permission_name: str) -> list[OAAPermission]:
    value = permission_name.lower()
    actions = [OAAPermission.DataRead]
    if any(x in value for x in ["write", "edit", "update", "create", "delete", "manage"]):
        actions.append(OAAPermission.DataWrite)
    if "admin" in value or "owner" in value or "security" in value:
        actions.append(OAAPermission.MetadataRead)
        actions.append(OAAPermission.MetadataWrite)
    unique = []
    for action in actions:
        if action not in unique:
            unique.append(action)
    return unique


def build_oaa_payload(config: dict[str, Any], query_data: dict[str, list[dict[str, Any]]]) -> tuple[CustomApplication, dict[str, int]]:
    app = CustomApplication(
        name=config["datasource_name"],
        application_type=config["provider_name"],
        description=f"Generic JDBC connector for {config['application_name']}",
    )

    cols = config["columns"]

    roles_raw = query_data.get("roles", [])
    users_raw = query_data.get("users", [])
    groups_raw = query_data.get("groups", [])
    user_role_raw = query_data.get("user_role", [])
    user_group_raw = query_data.get("user_group", [])
    role_perm_raw = query_data.get("role_permission", [])
    user_perm_raw = query_data.get("user_permission", [])

    roles_by_id: dict[str, str] = {}
    for row in roles_raw:
        role_id = _get_value(row, cols["roles_col_id"])
        role_name = _get_value(row, cols["roles_col_name"]) or role_id
        if role_id:
            roles_by_id[role_id] = role_name

    groups_by_id: dict[str, str] = {}
    for row in groups_raw:
        group_id = _get_value(row, cols["groups_col_id"])
        group_name = _get_value(row, cols["groups_col_name"]) or group_id
        if group_id:
            groups_by_id[group_id] = group_name

    role_assignments: dict[str, set[str]] = {}
    user_groups: dict[str, set[str]] = {}

    for row in user_role_raw:
        user_id = _get_value(row, cols["user_role_col_user_id"])
        role_id = _get_value(row, cols["user_role_col_role_id"])
        if user_id and role_id:
            role_assignments.setdefault(user_id, set()).add(role_id)

    for row in user_group_raw:
        user_id = _get_value(row, cols["user_group_col_user_id"])
        group_id = _get_value(row, cols["user_group_col_group_id"])
        if user_id and group_id:
            user_groups.setdefault(user_id, set()).add(group_id)

    for row in users_raw:
        user_id = _get_value(row, cols["users_col_id"])
        role_id = _get_value(row, cols["users_col_role_id"])
        group_id = _get_value(row, cols["users_col_group_id"])
        if user_id and role_id:
            role_assignments.setdefault(user_id, set()).add(role_id)
        if user_id and group_id:
            user_groups.setdefault(user_id, set()).add(group_id)

    role_permissions: dict[str, set[str]] = {}
    user_permissions: dict[str, set[str]] = {}

    for row in role_perm_raw:
        role_id = _get_value(row, cols["role_permission_col_role_id"])
        perm = _get_value(row, cols["role_permission_col_permission"]).lower()
        if role_id and perm:
            role_permissions.setdefault(role_id, set()).add(perm)

    for row in user_perm_raw:
        user_id = _get_value(row, cols["user_permission_col_user_id"])
        perm = _get_value(row, cols["user_permission_col_permission"]).lower()
        if user_id and perm:
            user_permissions.setdefault(user_id, set()).add(perm)

    if not roles_by_id and role_assignments:
        for role_id_set in role_assignments.values():
            for role_id in role_id_set:
                roles_by_id.setdefault(role_id, role_id)

    custom_permissions = set(config["custom_permissions"])
    for perm_set in role_permissions.values():
        custom_permissions.update(perm_set)
    for perm_set in user_permissions.values():
        custom_permissions.update(perm_set)

    if not custom_permissions:
        custom_permissions = {"read", "write", "admin"}

    for perm_name in sorted(custom_permissions):
        app.add_custom_permission(perm_name, _perm_actions(perm_name))

    local_roles: dict[str, Any] = {}
    for role_id, role_name in sorted(roles_by_id.items()):
        local_roles[role_id] = app.add_local_role(role_name)

    for group_name in sorted(groups_by_id.values()):
        app.add_local_group(group_name)

    users_added = 0
    for row in users_raw:
        user_id = _get_value(row, cols["users_col_id"])
        if not user_id:
            continue

        user_name = _get_value(row, cols["users_col_full_name"])
        email = _get_value(row, cols["users_col_email"])

        local_user = app.add_local_user(user_id)
        if user_name:
            local_user.full_name = user_name
        if email:
            local_user.email = email

        for role_id in sorted(role_assignments.get(user_id, set())):
            role_name = roles_by_id.get(role_id)
            if role_name:
                local_user.add_role(role_name, apply_to_application=True)

        for group_id in sorted(user_groups.get(user_id, set())):
            group_name = groups_by_id.get(group_id)
            if group_name:
                local_user.add_group(group_name)

        for perm_name in sorted(user_permissions.get(user_id, set())):
            local_user.add_permissions([perm_name])

        users_added += 1

    for role_id, permissions in role_permissions.items():
        role_obj = local_roles.get(role_id)
        if role_obj:
            role_obj.add_permissions(sorted(permissions))

    stats = {
        "users": users_added,
        "roles": len(local_roles),
        "groups": len(groups_by_id),
        "permissions": len(custom_permissions),
    }

    return app, stats


def push_to_veza(
    config: dict[str, Any],
    app: CustomApplication,
    save_json: bool,
) -> None:
    if save_json:
        json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "payload.json")
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump(app.get_payload(), handle, indent=2)
        log.info("OAA payload saved: %s", json_path)

    try:
        client = OAAClient(url=config["veza_url"], token=config["veza_api_key"])
        response = client.push_application(
            provider_name=config["provider_name"],
            data_source_name=config["datasource_name"],
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for warning in response["warnings"]:
                log.warning("Veza warning: %s", warning)
        log.info("Veza push completed successfully")
    except OAAClientError as exc:
        log.error("Veza push failed: %s - %s (HTTP %s)", exc.error, exc.message, exc.status_code)
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("Detail: %s", detail)
        sys.exit(1)


def main() -> None:
    print("=" * 60)
    print("  Generic JDBC Application -> Veza OAA Integration")
    print("=" * 60)

    args = parse_args()
    _setup_logging(args.log_level)
    config = load_config(args)

    log.info("Starting connector for application '%s'", config["application_name"])
    conn = get_db_connection(config)

    query_data: dict[str, list[dict[str, Any]]] = {}
    for query_name, query_text in config["queries"].items():
        if not query_text:
            continue
        log.info("Running query: %s", query_name)
        query_data[query_name] = execute_query(conn, query_text)
        log.info("Rows fetched for %s: %d", query_name, len(query_data[query_name]))

    conn.close()

    app, stats = build_oaa_payload(config, query_data)
    log.info(
        "Payload assembled: users=%d roles=%d groups=%d permissions=%d",
        stats["users"],
        stats["roles"],
        stats["groups"],
        stats["permissions"],
    )

    push_to_veza(config, app, save_json=args.save_json)
    log.info("Connector run complete")


if __name__ == "__main__":
    main()
