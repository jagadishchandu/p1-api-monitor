"""
P1 API Monitor - ServiceNow incidents -> Teams and email alerts, plus the SWAT board.

Reads incidents from the ServiceNow Table API (no browser, no Okta login, no MFA).
Every check asks ServiceNow for incidents in the states In Progress, On Hold and
Resolved, then:
    - alerts the Teams channel(s) and/or email list when a new incident appears,
      its priority changes, or an In Progress incident moves to On Hold / Resolved
    - keeps On Hold and Resolved incidents in incidents.json (with their state) so the
      SWAT board can show and filter them
    - serves the SWAT board on port 8080 (SWAT_BOARD_PORT)

All settings come from environment variables (see .env.example and README.md).
Run once:          python monitor.py --check-once
Send a test card:  python monitor.py --test-notify
Normal run:        python monitor.py        (checks every MONITOR_INTERVAL_MINUTES, default 15)
"""

import argparse
import os
import re
import smtplib
import socket
import ssl
import sys
import threading
import time
from datetime import datetime
from email.message import EmailMessage
from html import escape as html_escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import json

import requests
import urllib3
from azure.core import MatchConditions
from azure.core.exceptions import AzureError, ResourceExistsError, ResourceModifiedError, ResourceNotFoundError
from azure.storage.blob import BlobServiceClient, ContentSettings


# ---------------------------------------------------------------------------
# Configuration (environment variables)
# ---------------------------------------------------------------------------

# incidents.json, swat_status.json and swat_details/ are stored as blobs in an Azure Storage container,
# inside the folder set by AZURE_STORAGE_FOLDER. Nothing is written to the local disk.
STORAGE_INCIDENTS = "incidents.json"
STORAGE_STATUS = "swat_status.json"
STORAGE_NOTES_FOLDER = "swat_details"

# ServiceNow incident state codes used in the query. The display names come back in the API responses.
SN_STATE_CODES = {"In Progress": "2", "On Hold": "3", "Resolved": "6"}
SN_PAGE_SIZE = 200
SN_TIMEOUT_SECONDS = 60

# Teams card colour per priority number (the emoji matches the colour).
PRIORITY_STYLES = {
    1: ("attention", "🔴"),   # 1 - Critical
    2: ("warning", "🟠"),     # 2 - High
    3: ("accent", "🔵"),      # 3 - Moderate
    4: ("good", "🟢"),        # 4 - Low
    5: ("emphasis", "⚪"),     # 5 - Planning
}

# Card colour for state-change follow-ups, by the state the incident moved TO.
STATE_CHANGE_STYLES = {
    "Resolved": ("good", "✅"),
    "Closed": ("good", "✅"),
    "On Hold": ("warning", "⏸️"),
    "Canceled": ("emphasis", "🚫"),
    "Cancelled": ("emphasis", "🚫"),
    "_default": ("accent", "🔄"),
}

EMAIL_PRIORITY_COLOURS = {1: "#c62828", 2: "#ef6c00", 3: "#f9a825"}


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


def env_list(name: str) -> list:
    """A comma or semicolon separated environment variable -> list of clean, unique, non-empty values."""
    items = []
    for item in re.split(r"[;,]", os.environ.get(name, "")):
        item = item.strip().strip("'\"").strip()
        if item and item.lower() not in [i.lower() for i in items]:
            items.append(item)
    return items


def load_config() -> dict:
    config = {
        "sn_instance": os.environ.get("SN_INSTANCE", "").strip(),
        "sn_client_id": os.environ.get("SN_CLIENT_ID", "").strip(),
        "sn_client_secret": os.environ.get("SN_CLIENT_SECRET", ""),
        "storage_connection_string": os.environ.get("AZURE_STORAGE_CONNECTION_STRING", "").strip(),
        "storage_container": os.environ.get("AZURE_STORAGE_CONTAINER", "p1-api-monitor").strip(),
        "storage_folder": os.environ.get("AZURE_STORAGE_FOLDER", "p1-api-monitor").strip().strip("/"),
        "teams_webhook_urls": env_list("TEAMS_WEBHOOK_URLS"),
        "teams_verify_ssl": env_bool("TEAMS_VERIFY_SSL", True),
        "email_to": env_list("EMAIL_TO"),
        "email_cc": env_list("EMAIL_CC"),
        "email_bcc": env_list("EMAIL_BCC"),
        "smtp_host": os.environ.get("SMTP_HOST", "").strip(),
        "smtp_port": int(os.environ.get("SMTP_PORT", "587")),
        "smtp_user": os.environ.get("SMTP_USER", "").strip(),
        "smtp_password": os.environ.get("SMTP_PASSWORD", ""),
        "smtp_from": os.environ.get("SMTP_FROM", "").strip(),
        "smtp_starttls": env_bool("SMTP_STARTTLS", True),
        "interval_minutes": int(os.environ.get("MONITOR_INTERVAL_MINUTES", "15")),
        "swat_board_enabled": env_bool("SWAT_BOARD_ENABLED", True),
        "swat_board_port": int(os.environ.get("SWAT_BOARD_PORT", "8080")),
        # Empty in .env means "use the address the image was built with" (SWAT_BOARD_DEFAULT_URL, set by the Dockerfile).
        "swat_board_public_url": (os.environ.get("SWAT_BOARD_PUBLIC_URL", "").strip()
                                  or os.environ.get("SWAT_BOARD_DEFAULT_URL", "").strip() or None),
    }
    if not config["sn_instance"]:
        raise ValueError("missing required environment variable(s): SN_INSTANCE")
    required = [
        ("SN_CLIENT_ID", "sn_client_id"),
        ("SN_CLIENT_SECRET", "sn_client_secret"),
        ("AZURE_STORAGE_CONNECTION_STRING", "storage_connection_string"),
    ]
    missing = [name for name, key in required if not config[key]]
    if missing:
        raise ValueError(f"missing required environment variable(s): {', '.join(missing)}")
    if config["interval_minutes"] < 1:
        raise ValueError("MONITOR_INTERVAL_MINUTES must be 1 or more")
    if not config["teams_webhook_urls"]:
        print("NOTE: TEAMS_WEBHOOK_URLS is empty - no Teams alerts will be sent.", file=sys.stderr)
    if not (config["email_to"] or config["email_cc"] or config["email_bcc"]):
        print("NOTE: no EMAIL_TO / EMAIL_CC / EMAIL_BCC set - no email alerts will be sent.", file=sys.stderr)
    return config


# ---------------------------------------------------------------------------
# ServiceNow Table API
# ---------------------------------------------------------------------------

class ServiceNowError(Exception):
    pass


SN_TOKEN_SKEW_SECONDS = 60  # refresh the OAuth token this long before it expires
_sn_token = {"value": None, "expires_at": 0.0}


def get_oauth_token(config: dict) -> dict:
    """OAuth 2.0 client credentials grant against the instance's token endpoint."""
    url = f"https://{config['sn_instance']}.service-now.com/oauth_token.do"
    try:
        resp = requests.post(
            url,
            data={
                "grant_type": "client_credentials",
                "client_id": config["sn_client_id"],
                "client_secret": config["sn_client_secret"],
            },
            headers={"Accept": "application/json"},
            timeout=SN_TIMEOUT_SECONDS,
        )
    except requests.RequestException as exc:
        raise ServiceNowError(f"could not reach the ServiceNow token endpoint: {exc}")
    if not resp.ok:
        raise ServiceNowError(
            f"OAuth token request failed (HTTP {resp.status_code}). Check SN_CLIENT_ID, SN_CLIENT_SECRET "
            f"and that the OAuth application is active. Response: {resp.text[:200]}"
        )
    body = resp.json()
    token = body.get("access_token")
    if not token:
        raise ServiceNowError("OAuth token response did not contain an access_token.")
    expires_in = int(body.get("expires_in", 1800))
    return {"value": token, "expires_at": time.time() + expires_in - SN_TOKEN_SKEW_SECONDS}


def authenticate(config: dict, session: requests.Session, force: bool = False) -> None:
    """Set the OAuth bearer token on the session. The token is cached until it nears expiry.
    force=True fetches a new token."""
    if force or not _sn_token["value"] or time.time() >= _sn_token["expires_at"]:
        _sn_token.update(get_oauth_token(config))
    session.headers["Authorization"] = f"Bearer {_sn_token['value']}"


def fetch_incidents(config: dict) -> tuple:
    """Ask ServiceNow for every incident in In Progress, On Hold or Resolved.
    Returns (in_progress, other_states):
        in_progress  - {INC number: incident data} for incidents In Progress
        other_states - {INC number: 'On Hold' or 'Resolved'}
    Raises ServiceNowError when ServiceNow cannot be read. Nothing is changed in that case."""
    url = f"https://{config['sn_instance']}.service-now.com/api/now/table/incident"
    query = "^OR".join(f"state={code}" for code in SN_STATE_CODES.values()) + "^ORDERBYnumber"
    fields = "number,sys_id,priority,state,short_description,sys_created_on"

    session = requests.Session()
    session.headers["Accept"] = "application/json"
    authenticate(config, session)

    rows = []
    offset = 0
    while True:
        params = {
            "sysparm_query": query,
            "sysparm_fields": fields,
            "sysparm_display_value": "true",          # state and priority as text, e.g. "In Progress", "1 - Critical"
            "sysparm_exclude_reference_link": "true",
            "sysparm_limit": SN_PAGE_SIZE,
            "sysparm_offset": offset,
        }
        try:
            resp = session.get(url, params=params, timeout=SN_TIMEOUT_SECONDS)
            if resp.status_code == 401:
                authenticate(config, session, force=True)  # the token may have expired early - get a new one once
                resp = session.get(url, params=params, timeout=SN_TIMEOUT_SECONDS)
        except requests.RequestException as exc:
            raise ServiceNowError(f"could not reach {config['sn_instance']}.service-now.com: {exc}")
        if resp.status_code == 401:
            raise ServiceNowError(
                "ServiceNow rejected the login (HTTP 401). Check SN_CLIENT_ID and SN_CLIENT_SECRET, "
                "and that the OAuth application is active and runs as the service account."
            )
        if resp.status_code == 403:
            raise ServiceNowError("ServiceNow refused access (HTTP 403). The account needs read access to the incident table.")
        if not resp.ok:
            raise ServiceNowError(f"ServiceNow returned HTTP {resp.status_code}: {resp.text[:300]}")
        page = resp.json().get("result", [])
        rows.extend(page)
        if len(page) < SN_PAGE_SIZE:
            break
        offset += SN_PAGE_SIZE

    in_progress, other_states = {}, {}
    for row in rows:
        number = (row.get("number") or "").strip()
        state = (row.get("state") or "").strip()
        if not number:
            continue
        if state == "In Progress":
            sys_id = row.get("sys_id") or ""
            short_description = (row.get("short_description") or "").strip()
            in_progress[number] = {
                "number": number,
                "sys_id": sys_id,
                "priority": (row.get("priority") or "").strip(),
                "state": state,
                "short_description": short_description,
                "created": row.get("sys_created_on") or "",
                "raw_text": short_description,
                "href": f"https://{config['sn_instance']}.service-now.com/nav_to.do?uri=incident.do?sys_id={sys_id}",
            }
        elif state in ("On Hold", "Resolved"):
            other_states[number] = state
    return in_progress, other_states


# ---------------------------------------------------------------------------
# Alert text and styling
# ---------------------------------------------------------------------------

def priority_style(priority):
    """(container_style, emoji) for a priority like '2 - High', or (None, None) when unreadable."""
    match = re.match(r"\s*([1-5])\b", priority or "")
    return PRIORITY_STYLES.get(int(match.group(1)), (None, None)) if match else (None, None)


def priority_number(priority):
    match = re.match(r"\s*(\d)", str(priority or ""))
    return int(match.group(1)) if match else None


def teams_card(config: dict, inc: dict) -> dict:
    """Adaptive Card for one incident. The card itself is the POST body, which is what the Power Automate flow expects."""
    number = inc.get("number") or "Unknown"
    priority = inc.get("priority")
    previous_priority = inc.get("previous_priority")
    state_change = inc.get("state_change")
    snippet = (inc.get("raw_text") or "")[:300].replace("\n", " ")
    short_description = inc.get("short_description")

    title = f"Priority Changed: {number}" if previous_priority else f"New In Progress Incident: {number}"
    container_style, priority_emoji = priority_style(priority)
    if state_change:
        # Follow-up card: colour follows the NEW state, not the priority.
        container_style, priority_emoji = STATE_CHANGE_STYLES.get(state_change["to"], STATE_CHANGE_STYLES["_default"])
        title = f"Update: {number} moved to {state_change['to']}"
    if priority_emoji:
        title = f"{priority_emoji} {title}"

    body = [{"type": "TextBlock", "text": title, "weight": "Bolder", "size": "Medium", "wrap": True}]
    if state_change:
        body.append({"type": "TextBlock", "text": f"State: {state_change['from']} -> {state_change['to']}", "wrap": True})
    if previous_priority:
        body.append({"type": "TextBlock", "text": f"Priority: {previous_priority} -> {priority}", "wrap": True})
    elif priority:
        body.append({"type": "TextBlock", "text": f"Priority: {priority}", "wrap": True})
    if short_description:
        body.append({"type": "TextBlock", "text": f"Short Description: {short_description}", "wrap": True})
    if inc.get("created"):
        body.append({"type": "TextBlock", "text": f"Created: {inc['created']}", "wrap": True})
    if snippet and snippet != short_description:
        body.append({"type": "TextBlock", "text": snippet, "wrap": True})
    if container_style:
        body = [{"type": "Container", "style": container_style, "bleed": True, "items": body}]

    card = {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": body,
    }
    actions = []
    if inc.get("href"):
        actions.append({"type": "Action.OpenUrl", "title": "Open in ServiceNow", "url": inc["href"]})
    if SWAT_BOARD_URL:
        actions.append({"type": "Action.OpenUrl", "title": "Open SWAT board", "url": SWAT_BOARD_URL})
    if actions:
        card["actions"] = actions
    return card


def notify_teams(config: dict, incidents: list):
    """Post one card per incident to every webhook. Returns one boolean per incident (True if a webhook accepted
    it), or None when no webhook is configured."""
    urls = config["teams_webhook_urls"]
    if not urls:
        return None
    verify = config["teams_verify_ssl"]
    if not verify:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    delivered = []
    for inc in incidents:
        number = inc.get("number") or "Unknown"
        card = teams_card(config, inc)
        accepted = False
        for idx, url in enumerate(urls, start=1):
            label = f"{number} -> webhook {idx}/{len(urls)}"
            try:
                resp = requests.post(url, json=card, timeout=15, verify=verify)
                if resp.ok:
                    print(f"Teams notification sent for {label} (HTTP {resp.status_code}).")
                    accepted = True
                else:
                    print(f"WARNING: Teams webhook rejected {label} ({resp.status_code}): {resp.text[:300]}", file=sys.stderr)
            except Exception as exc:
                print(f"WARNING: failed to send Teams notification for {label}: {exc}", file=sys.stderr)
            time.sleep(1)  # small pause between posts
        delivered.append(accepted)
    return delivered


def email_heading(inc: dict) -> tuple:
    number = inc.get("number") or "Unknown"
    priority = inc.get("priority") or "No priority"
    if inc.get("state_change"):
        change = inc["state_change"]
        return f"{number} - moved to {change['to']}", f"Moved from {change['from']} to {change['to']}"
    if inc.get("previous_priority"):
        return f"[{priority}] {number} - priority changed", f"Priority changed from {inc['previous_priority']} to {priority}"
    return f"[{priority}] {number} - {inc.get('short_description') or ''}".rstrip(" -"), "New incident"


def email_message(config: dict, inc: dict) -> EmailMessage:
    subject, heading = email_heading(inc)
    rows = [
        ("Incident", inc.get("number")),
        ("Priority", inc.get("priority")),
        ("Short description", inc.get("short_description")),
        ("Created", inc.get("created")),
        ("State", (inc.get("state_change") or {}).get("to") or inc.get("state")),
    ]
    colour = EMAIL_PRIORITY_COLOURS.get(priority_number(inc.get("priority")), "#1e4fb8")
    table = "".join(
        f"<tr><td style='padding:4px 10px;color:#555'>{html_escape(k)}</td>"
        f"<td style='padding:4px 10px'>{html_escape(str(v or ''))}</td></tr>"
        for k, v in rows
    )
    button = ""
    if inc.get("href"):
        button = (
            f"<p><a href='{html_escape(inc['href'])}' style='background:#1e6fd9;color:#fff;padding:8px 14px;"
            f"text-decoration:none;border-radius:6px'>Open in ServiceNow</a></p>"
        )
    html = (
        "<div style='font-family:Segoe UI,Arial,sans-serif'>"
        f"<div style='background:{colour};color:#fff;padding:12px 16px;font-size:16px'>{html_escape(heading)}</div>"
        f"<table style='border-collapse:collapse;margin-top:10px'>{table}</table>{button}</div>"
    )
    text = heading + "\n" + "\n".join(f"{k}: {v or ''}" for k, v in rows) + (f"\n{inc['href']}" if inc.get("href") else "")

    msg = EmailMessage()
    msg["From"] = config["smtp_from"] or config["smtp_user"] or "p1-api-monitor"
    if config["email_to"]:
        msg["To"] = ", ".join(config["email_to"])
    if config["email_cc"]:
        msg["Cc"] = ", ".join(config["email_cc"])
    msg["Subject"] = subject
    if priority_number(inc.get("priority")) == 1:
        msg["Importance"] = "High"
        msg["X-Priority"] = "1"
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    return msg


def notify_email(config: dict, incidents: list):
    """Send one email per incident through SMTP. Returns one boolean per incident, or None when no address is set."""
    to, cc, bcc = config["email_to"], config["email_cc"], config["email_bcc"]
    if not (to or cc or bcc):
        return None
    if not incidents:
        return []
    if not config["smtp_host"]:
        print("WARNING: email alerts need SMTP_HOST. Email skipped.", file=sys.stderr)
        return [False] * len(incidents)

    try:
        server = smtplib.SMTP(config["smtp_host"], config["smtp_port"], timeout=30)
    except Exception as exc:
        print(f"WARNING: could not connect to SMTP server {config['smtp_host']}: {exc}", file=sys.stderr)
        return [False] * len(incidents)

    results = []
    try:
        if config["smtp_starttls"]:
            server.starttls(context=ssl.create_default_context())
        if config["smtp_user"]:
            server.login(config["smtp_user"], config["smtp_password"])
        for inc in incidents:
            number = inc.get("number") or "Unknown"
            try:
                msg = email_message(config, inc)
                server.send_message(msg, to_addrs=to + cc + bcc)
                print(f"Email sent for {number}")
                results.append(True)
            except Exception as exc:
                print(f"WARNING: email failed for {number}: {exc}", file=sys.stderr)
                results.append(False)
    except Exception as exc:
        print(f"WARNING: SMTP session failed: {exc}", file=sys.stderr)
        results += [False] * (len(incidents) - len(results))
    finally:
        try:
            server.quit()
        except Exception:
            pass
    return results


# ---------------------------------------------------------------------------
# Check, compare with incidents.json, alert
# ---------------------------------------------------------------------------

def process_incidents(config: dict, current: dict, other_states: dict) -> None:
    """Compare this check with incidents.json, send alerts, and save the new state of every incident."""
    known = _read_json(STORAGE_INCIDENTS)
    now_str = _now()

    # New: never seen, or back In Progress after being On Hold / Resolved (those are kept in the file).
    new_numbers = set(current) - set(known)
    new_numbers |= {n for n in current if n in known and known[n].get("state", "In Progress") != "In Progress"}

    # Priority changed since the last check (both values must be present).
    changed_numbers = {
        n for n in set(current) & set(known)
        if current[n].get("priority") and known[n].get("priority") and current[n]["priority"] != known[n]["priority"]
    }

    # Was In Progress, now On Hold or Resolved. Only the change from In Progress is alerted.
    state_changes = {}
    for n, new_state in (other_states or {}).items():
        entry = known.get(n)
        if not entry or n in current:
            continue
        old_state = entry.get("state", "In Progress")
        if old_state == "In Progress":
            state_changes[n] = (old_state, new_state)

    print(
        f"[{now_str}] In Progress incidents found: {len(current)} "
        f"(new: {len(new_numbers)}, priority changed: {len(changed_numbers)}, "
        f"state changed: {len(state_changes)}, previously known: {len(known)})"
    )

    undelivered_new, undelivered_priority, undelivered_state = set(), set(), set()
    if new_numbers or changed_numbers or state_changes:
        alerts, kinds = [], []
        for n in sorted(new_numbers):
            alerts.append(current[n]); kinds.append(("new", n))
        for n in sorted(changed_numbers):
            alerts.append(dict(current[n], previous_priority=known[n]["priority"])); kinds.append(("priority", n))
        for n, (old_state, new_state) in sorted(state_changes.items()):
            alerts.append(dict(known[n], state_change={"from": old_state, "to": new_state})); kinds.append(("state", n))

        try:
            teams_result = notify_teams(config, alerts)
        except Exception as exc:
            print(f"WARNING: Teams notification failed: {exc}", file=sys.stderr)
            teams_result = [False] * len(alerts)
        try:
            email_result = notify_email(config, alerts)
        except Exception as exc:
            print(f"WARNING: email notification failed: {exc}", file=sys.stderr)
            email_result = [False] * len(alerts)

        # An alert counts as delivered when at least one configured channel accepted it.
        if teams_result is None and email_result is None:
            delivered = [True] * len(alerts)  # nothing configured - nothing to retry
        elif teams_result is None:
            delivered = email_result
        elif email_result is None:
            delivered = teams_result
        else:
            delivered = [a or b for a, b in zip(teams_result, email_result)]

        for (kind, n), ok in zip(kinds, delivered):
            if not ok:
                {"new": undelivered_new, "priority": undelivered_priority, "state": undelivered_state}[kind].add(n)
        sent = sorted(n for (kind, n), ok in zip(kinds, delivered) if ok)
        if sent:
            print(f"Alert sent for: {', '.join(sent)}")
        failed = sorted({n for _, n in kinds} - set(sent))
        if failed:
            print(f"WARNING: no channel accepted the alert for: {', '.join(failed)} - will retry on the next check.", file=sys.stderr)
    else:
        print("No new, priority-changed or state-changed incidents (no duplicate alerts sent).")

    # Save: keep every incident, update the latest data, and record its state.
    merged = dict(known)
    for number, data in current.items():
        if number in undelivered_new:
            continue  # not delivered - stays unknown so it is "new" again next check
        existing = merged.get(number, {})
        entry = dict(existing)
        entry.update(data)
        if not data.get("priority") and existing.get("priority"):
            entry["priority"] = existing["priority"]  # a missing priority must not erase the last known one
        if number in undelivered_priority:
            entry["priority"] = existing["priority"]  # keep the old value so the change is retried
        entry["first_seen"] = existing.get("first_seen", data.get("first_seen", now_str))
        entry["last_seen_in_progress"] = now_str
        entry["state"] = "In Progress"
        merged[number] = entry

    # On Hold / Resolved incidents are KEPT with their new state (the SWAT board filters on it).
    for number, new_state in (other_states or {}).items():
        if number in current or number not in merged or number in undelivered_state:
            continue
        merged[number] = dict(merged[number], state=new_state, state_at=now_str)

    # Anything no longer On Hold, Resolved or In Progress (Closed, Canceled, reassigned, ...) is removed.
    # The API answer is complete, so this is safe. Incidents whose alert is still being retried are kept.
    removed = []
    for number in sorted(set(merged) - set(current) - set(other_states or {})):
        if number in undelivered_state:
            continue
        del merged[number]
        removed.append(number)
    if removed:
        print(f"Removed from incidents.json (no longer On Hold, Resolved or In Progress): {', '.join(removed)}")

    _write_json(STORAGE_INCIDENTS, merged)


def check_once(config: dict) -> None:
    current, other_states = fetch_incidents(config)
    process_incidents(config, current, other_states)


def watch(config: dict) -> None:
    interval = config["interval_minutes"]
    print(f"Checking ServiceNow every {interval} minute(s). Press Ctrl+C to stop.")
    while True:
        try:
            check_once(config)
        except ServiceNowError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
        except Exception as exc:
            print(f"ERROR: unexpected failure: {exc}", file=sys.stderr)
        time.sleep(interval * 60)


# ---------------------------------------------------------------------------
# SWAT board (served on SWAT_BOARD_PORT, default 8080)
# ---------------------------------------------------------------------------

SWAT_BOARD_URL = None  # set by start_swat_board() when the board is running


def private_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # no packet is sent; this only picks the outgoing interface
            return s.getsockname()[0]
    except OSError:
        return socket.gethostbyname(socket.gethostname())


def start_swat_board(config: dict) -> None:
    global SWAT_BOARD_URL
    if not config["swat_board_enabled"]:
        return
    port = config["swat_board_port"]
    try:
        start_in_background(host="0.0.0.0", port=port)
    except OSError as exc:
        print(f"ERROR: SWAT board could not start on port {port}: {exc}", file=sys.stderr)
        sys.exit(1)
    SWAT_BOARD_URL = config["swat_board_public_url"] or f"http://{private_ip()}:{port}"
    print(f"SWAT board running on port {port}. Teams card link: {SWAT_BOARD_URL}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="P1 API Monitor: ServiceNow incidents -> Teams/email alerts + SWAT board")
    parser.add_argument("--check-once", action="store_true", help="Run one check and exit (no SWAT board, no loop)")
    parser.add_argument("--test-notify", action="store_true", help="Send one fake P1 alert to Teams and email, then exit")
    args = parser.parse_args()

    try:
        config = load_config()
        init_storage(config)
    except (ValueError, AzureError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.test_notify:
        fake = {
            "number": "INC0000000",
            "priority": "1 - Critical",
            "short_description": "TEST - sample short description",
            "created": "2026-10-03 08:00:00",
            "sys_id": "",
            "href": None,
            "raw_text": "TEST - this is a test notification from p1_api_monitor --test-notify",
        }
        teams = notify_teams(config, [fake])
        email = notify_email(config, [fake])
        print(f"Teams: {teams}  Email: {email}")
        return

    if args.check_once:
        check_once(config)
        return

    start_swat_board(config)
    watch(config)


# ---------------------------------------------------------------------------
# SWAT board: shared Required / Joined choices, people who joined, and a details & notes page.
# Served in the background while the monitor runs (see start_swat_board). Its page is at the monitor's address.
# ---------------------------------------------------------------------------
TEAMS = {"infra": "Infra Ops", "container": "Container Ops", "network": "Network Ops"}
REQUIRED_VALUES = {"required": "Required", "not_required": "Not required"}
INCIDENT_ID = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
MAX_NOTES_CHARS = 200_000
SAVE_RETRIES = 5  # how many times a save is retried when another board user saved at the same moment


def _now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# ---------------------------------------------------------------------------
# Azure Storage: blobs in one container, inside one folder (AZURE_STORAGE_CONTAINER / AZURE_STORAGE_FOLDER)
# ---------------------------------------------------------------------------

STORAGE = {"container": None, "folder": ""}  # set by init_storage()
JSON_TYPE = ContentSettings(content_type="application/json")


class StorageConflict(Exception):
    """A blob was changed by someone else between our read and our write."""


FOLDER_MARKER = ".folder"  # empty placeholder blob, so an empty folder shows up in Azure Storage Explorer


def init_storage(config: dict) -> None:
    """Connect to the storage account, create the container and folders if they are missing.
    Raises ValueError or AzureError."""
    service = BlobServiceClient.from_connection_string(config["storage_connection_string"])
    container = service.get_container_client(config["storage_container"])
    try:
        container.create_container()
        print(f"Created storage container '{config['storage_container']}'.")
    except ResourceExistsError:
        pass
    STORAGE["container"] = container
    STORAGE["folder"] = config["storage_folder"]

    # Blob storage has no real folders: a folder exists once a blob name starts with it.
    # Create the data folder and the notes folder with placeholder blobs, if they are not there yet.
    for name in (FOLDER_MARKER, f"{STORAGE_NOTES_FOLDER}/{FOLDER_MARKER}"):
        try:
            _blob(name).upload_blob(b"", overwrite=False)
        except ResourceExistsError:
            pass


def _blob(name):
    folder = STORAGE["folder"]
    return STORAGE["container"].get_blob_client(f"{folder}/{name}" if folder else name)


def _download(name):
    """Returns (data, etag). data is None when the blob does not exist yet."""
    try:
        downloader = _blob(name).download_blob()
    except ResourceNotFoundError:
        return None, None
    data = json.loads(downloader.readall() or b"{}")
    return (data if isinstance(data, dict) else {}), downloader.properties.etag


def _read_json(name):
    data, _ = _download(name)
    return data or {}


def _write_json(name, data):
    """Overwrite the blob. Used by the monitor, which is the only writer of incidents.json."""
    _blob(name).upload_blob(json.dumps(data, indent=2).encode("utf-8"), overwrite=True, content_settings=JSON_TYPE)


def _write_json_if(name, data, etag):
    """Write only if nobody changed the blob since it was read (etag). etag None means the blob must not exist yet.
    Raises StorageConflict otherwise."""
    payload = json.dumps(data, indent=2).encode("utf-8")
    try:
        if etag is None:
            _blob(name).upload_blob(payload, overwrite=False, content_settings=JSON_TYPE)
        else:
            _blob(name).upload_blob(
                payload, overwrite=True, etag=etag, match_condition=MatchConditions.IfNotModified,
                content_settings=JSON_TYPE,
            )
    except (ResourceExistsError, ResourceModifiedError):
        raise StorageConflict(name)


def _update_json(name, change):
    """Read a JSON blob, let change(data) edit it and return (saved, message), then write it back.
    Retries when another writer saved in between. Returns (saved, message).
    Raises TimeoutError if it keeps losing the race."""
    for _ in range(SAVE_RETRIES):
        data, etag = _download(name)
        data = data or {}
        saved, message = change(data)
        if not saved:
            return False, message
        try:
            _write_json_if(name, data, etag)
            return True, message
        except StorageConflict:
            continue
    raise TimeoutError("the data was changed by someone else at the same time; try again")


# ---------------------------------------------------------------- team choices and who joined

def set_choice(incident, team, field, value, name):
    """field "required" (value required / not_required), or field "joined" (value = the name of a person who joined).
    Returns (saved, message)."""
    def change(status):
        team_entry = status.setdefault(incident, {}).setdefault(team, {})
        now = _now()
        if field == "required":
            if team_entry.get("required"):
                prev = team_entry["required"]
                return False, f"Already set to {REQUIRED_VALUES[prev['value']]} by {prev['by']} at {prev['at']}."
            team_entry["required"] = {"value": value, "by": name, "at": now}
        else:  # joined
            if team_entry.get("required", {}).get("value") != "required":
                return False, "Mark this team as Required before people can join."
            joined = team_entry.setdefault("joined", [])
            if any(p["name"].lower() == value.lower() for p in joined):
                return False, f"{value} is already listed as joined."
            joined.append({"name": value, "added_by": name, "at": now})
        return True, "Saved."

    return _update_json(STORAGE_STATUS, change)


# ---------------------------------------------------------------- details & notes (one blob per incident)

def _notes_name(incident):
    return f"{STORAGE_NOTES_FOLDER}/{incident}.json"


INTAKE_QUESTIONS = [
    ("subscription", "What is the Subscription name"),
    ("cloud", "Is App Cloud based or On-prem"),
    ("priority", "What is the priority"),
    ("incident", "What is the incident number"),
    ("itask", "Itask number"),
    ("issue_start", "When did the issue start"),
    ("env", "Is Env Prod or Non-Prod"),
    ("changes", "Were there any changes done to the env recently"),
    ("pattern", "Is the issue intermittent or consistent"),
    ("impact", "How many users/apps are impacted"),
    ("first_time", "Is the issue happening for the first time or its repetitive"),
    ("toc_received", "TOC Call Received Time"),
    ("toc_joined", "TOC Call Joined Time"),
    ("toc_closed", "TOC Closed/All Clear Time"),
    ("issue", "Issue:"),
]
INTAKE_KEYS = {key for key, _ in INTAKE_QUESTIONS}
TIME_KEYS = {"issue_start", "toc_received", "toc_joined", "toc_closed"}  # answered with a date and time picker


def _display_time(value):
    """'2026-10-15T09:30' from the date and time picker -> '10/15/2026 09:30 AM'. Other text is kept as typed."""
    try:
        return datetime.strptime(value.strip(), "%Y-%m-%dT%H:%M").strftime("%m/%d/%Y %I:%M %p")
    except (ValueError, AttributeError):
        return value


def _notes_view(data):
    return {
        "text": data.get("text", ""),
        "version": int(data.get("version", 0)),
        "updated_at": data.get("updated_at"),
        "updated_by": data.get("updated_by"),
        "answers": data.get("answers") or {},
        "rca": data.get("rca", ""),
        "history": data.get("history") or [],
    }


def read_notes(incident):
    data, _ = _download(_notes_name(incident))
    return _notes_view(data or {})


def save_notes(incident, text, base_version, name, answers=None, rca=None):
    """Save if nobody saved since base_version. answers / rca of None keep what is already saved.
    Returns (saved, notes)."""
    data, etag = _download(_notes_name(incident))
    current = _notes_view(data or {})
    if base_version != current["version"]:
        return False, current
    now = _now()
    version = current["version"] + 1
    new = {
        "incident": incident,
        "text": text,
        "version": version,
        "updated_at": now,
        "updated_by": name,
        "answers": current["answers"] if answers is None else answers,
        "rca": current["rca"] if rca is None else rca,
        "history": (current["history"] + [{"version": version, "by": name, "at": now}])[-500:],
    }
    try:
        _write_json_if(_notes_name(incident), new, etag)  # fails if someone saved after we read
    except StorageConflict:
        return False, read_notes(incident)
    return True, read_notes(incident)


def _cell_text(value):
    """Text for an Excel cell. A value that starts with = + - @ is shown as text, not as a formula."""
    value = "" if value is None else str(value)
    return " " + value if value[:1] in ("=", "+", "-", "@") else value


def export_filename(incident):
    """Excel name: INC number, priority and start time, e.g. INC24053551_1-Critical_2026-10-15_09-30-00.xlsx.
    Start time = the 'When did the issue start' answer, else the incident's created time, else now."""
    data = _read_json(STORAGE_INCIDENTS).get(incident, {})
    answers = read_notes(incident)["answers"]
    start = _display_time((answers.get("issue_start") or "").strip()) or str(data.get("created") or "").strip() or _now()
    priority = (data.get("priority") or "no-priority").replace(" ", "")
    name = "_".join([incident, priority, start])
    name = re.sub(r'[\\/:*?"<>|\s]+', "_", name).strip("_")
    return name[:150] + ".xlsx"


def _as_datetime(value):
    """'2026-10-15T09:30' from the date and time picker -> datetime. Anything else -> None."""
    try:
        return datetime.strptime(value.strip(), "%Y-%m-%dT%H:%M")
    except (ValueError, AttributeError):
        return None


def build_intake_workbook(incident):
    """Excel in the same layout, colours and fonts as the SWAT intake form: answers, RCA and the troubleshooting
    notes (each line already has its time). Time answers are real Excel dates. The save log is not included."""
    import io
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

    doc = read_notes(incident)
    incident_data = _read_json(STORAGE_INCIDENTS).get(incident, {})
    defaults = {"priority": incident_data.get("priority") or "", "incident": incident}
    thin = Side(style="thin")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    title_fill = PatternFill("solid", fgColor="AEAEAE")   # theme Background 2, darker 25%
    header_fill = PatternFill("solid", fgColor="156082")  # theme Accent 1

    wb = Workbook()
    ws = wb.active
    ws.title = "Sheet1"
    ws.column_dimensions["A"].width = 51.43
    ws.column_dimensions["B"].width = 85.57

    def cell(row, col, value, *, bold=False, header=False, halign=None, fmt=None):
        c = ws.cell(row=row, column=col, value=_cell_text(value) if isinstance(value, str) else value)
        c.font = Font(name="Aptos Narrow", size=11, bold=bold, color="FFFFFF" if header else "000000")
        if header:
            c.fill = header_fill
        c.alignment = Alignment(horizontal=halign, vertical="center" if header else "top", wrap_text=True)
        c.border = border
        if fmt:
            c.number_format = fmt
        return c

    def merged_row(row, value, *, header=False, bold=False, halign="left"):
        cell(row, 1, value, header=header, bold=bold, halign=halign)
        cell(row, 2, None, header=header)
        ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=2)

    # Title and column headers
    cell(1, 1, "SWAT INTAKE FORM", bold=True, halign="center").fill = title_fill
    cell(1, 2, None).fill = title_fill
    ws.merge_cells("A1:B1")
    cell(3, 1, "Question", header=True, halign="center")
    cell(3, 2, "Response", header=True, halign="center")

    # Intake questions
    row = 4
    for key, label in INTAKE_QUESTIONS:
        raw = doc["answers"].get(key) or defaults.get(key, "")
        cell(row, 1, label, halign="left")
        when = _as_datetime(raw) if key in TIME_KEYS else None
        if when:
            cell(row, 2, when, halign="left", fmt="m/d/yy h:mm")
        else:
            cell(row, 2, raw, halign="left")
        row += 1

    # RCA
    merged_row(row, "RCA", header=True, halign="center")
    row += 1
    merged_row(row, doc["rca"] or "NA", halign="center")
    row += 1

    # History of troubleshooting (every note line, with its time)
    merged_row(row, "History of Troubleshooting", header=True, bold=True, halign="center")
    row += 1
    for line in (doc["text"] or "").splitlines():
        if line.strip():
            merged_row(row, line)
            row += 1

    ws.sheet_view.showGridLines = True
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def incidents_for_page():
    raw = _read_json(STORAGE_INCIDENTS)
    out = []
    for number, data in sorted(raw.items()):
        text = (data.get("raw_text") or "").strip()
        out.append({
            "number": number,
            "priority": data.get("priority") or "",
            "text": text[:200],
            "state": data.get("state") or "In Progress",  # entries saved before state tracking are In Progress
            "state_at": data.get("state_at") or "",
        })
    return out


# ---------------------------------------------------------------- pages

BOARD_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SWAT board</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; background: #f3f6fb; margin: 0; padding: 20px; color: #1b2b44; }
  h1 { margin: 0 0 4px; font-size: 1.5rem; }
  .sub { color: #56657a; margin-bottom: 16px; }
  .bar { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-bottom: 18px; }
  .bar input { padding: 8px 10px; border: 1px solid #c5d2e4; border-radius: 8px; min-width: 220px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 16px; }
  .card { background: #fff; border-radius: 14px; box-shadow: 0 4px 14px rgba(20, 40, 80, 0.08); padding: 16px; }
  .card h2 { font-size: 1.05rem; margin: 0 0 6px; display: flex; justify-content: space-between; gap: 8px; }
  .pri { font-size: 0.8rem; background: #e7efff; color: #1e4fb8; border-radius: 999px; padding: 2px 10px; }
  .text { font-size: 0.9rem; color: #4a5a70; margin-bottom: 10px; min-height: 2.4em; }
  .details { font-size: 0.88rem; margin-bottom: 10px; display: inline-block; }
  .team { border: 1px solid #e0e7f2; border-radius: 10px; padding: 10px; margin-bottom: 10px; }
  .team.has-joined { background: #eefaf2; border-color: #bfe6cc; }
  .team strong { display: block; margin-bottom: 6px; }
  .row { display: flex; gap: 14px; align-items: center; flex-wrap: wrap; }
  .row label { cursor: pointer; }
  .row label.off { color: #4a5a70; }
  .hint { font-size: 0.8rem; color: #6b7a90; }
  .joined-list { margin: 6px 0; padding-left: 18px; font-size: 0.88rem; }
  .joined-list small { color: #6b7a90; }
  .add { display: flex; gap: 8px; margin-top: 6px; }
  .add input { flex: 1; padding: 6px 8px; border: 1px solid #c5d2e4; border-radius: 8px; }
  .add button { padding: 6px 12px; border-radius: 8px; border: 0; background: #1e6fd9; color: #fff; cursor: pointer; }
  .add button:disabled { background: #a9bedb; cursor: default; }
  .empty { color: #56657a; padding: 30px 0; }
  .msg { color: #b42318; min-height: 1.2em; margin-bottom: 10px; }
  .filters { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; }
  .filters button { padding: 6px 14px; border-radius: 999px; border: 1px solid #c5d2e4; background: #fff; color: #1b2b44; cursor: pointer; font-size: 0.9rem; }
  .filters button.active { background: #1e4fb8; border-color: #1e4fb8; color: #fff; }
  .state { font-size: 0.8rem; border-radius: 999px; padding: 2px 10px; background: #e7efff; color: #1e4fb8; }
  .state.on-hold { background: #fff4e0; color: #8a5a00; }
  .state.resolved { background: #e6f6ec; color: #17633a; }
</style></head>
<body>
  <h1>SWAT board</h1>
  <div class="sub">For each team, choose Required or Not required. Then add the people who joined. Everyone sees the same choices.</div>
  <div class="bar">
    <input id="name" placeholder="Your name (required to save)" maxlength="60">
    <span class="sub" id="updated"></span>
  </div>
  <div class="filters" id="filters"></div>
  <div class="msg" id="msg"></div>
  <div class="grid" id="grid"></div>
<script>
const TEAMS = [["infra", "Infra Ops"], ["container", "Container Ops"], ["network", "Network Ops"]];
const nameBox = document.getElementById("name");
nameBox.value = localStorage.getItem("swat-name") || "";
nameBox.addEventListener("change", () => localStorage.setItem("swat-name", nameBox.value.trim()));

function setMsg(text) { document.getElementById("msg").textContent = text || ""; }

function el(tag, attrs, children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "text") node.textContent = v; else node.setAttribute(k, v);
  }
  for (const c of children || []) node.appendChild(c);
  return node;
}

async function save(incident, team, field, value) {
  const name = nameBox.value.trim();
  if (!name) { setMsg("Enter your name first."); nameBox.focus(); load(); return false; }
  localStorage.setItem("swat-name", name);
  setMsg("");
  const r = await fetch("/api/set", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ incident, team, field, value, name }),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) setMsg(body.error || "Could not save.");
  load();
  return r.ok;
}

function teamBlock(incident, key, label, info) {
  const req = info.required || {};
  const joined = info.joined || [];
  const name = `${incident}-${key}`;
  const isRequired = req.value === "required";

  const radios = el("div", { class: "row" });
  for (const [value, text] of Object.entries({ required: "Required", not_required: "Not required" })) {
    const id = `${name}-${value}`;
    const radio = el("input", { type: "radio", name: name, id: id });
    radio.checked = req.value === value;
    radio.disabled = !!req.value;
    radio.addEventListener("change", () => { if (radio.checked) save(incident, key, "required", value); });
    radios.appendChild(el("label", { for: id, class: req.value && req.value !== value ? "off" : "" }, [radio, document.createTextNode(" " + text)]));
  }

  const block = el("div", { class: "team" + (joined.length ? " has-joined" : "") }, [el("strong", { text: label }), radios]);
  if (req.value) block.appendChild(el("span", { class: "hint", text: `${req.value === "required" ? "Required" : "Not required"}: chosen by ${req.by} at ${req.at}` }));
  else block.appendChild(el("span", { class: "hint", text: "Not chosen yet" }));

  block.appendChild(el("div", { class: "hint", style: "margin-top:8px", text: "Joined:" }));
  if (!joined.length) {
    block.appendChild(el("div", { class: "hint", text: isRequired ? "No one has joined yet." : "" }));
  } else {
    const list = el("ul", { class: "joined-list" });
    for (const p of joined) {
      list.appendChild(el("li", {}, [document.createTextNode(p.name + " "), el("small", { text: `(added by ${p.added_by} at ${p.at})` })]));
    }
    block.appendChild(list);
  }

  const addRow = el("div", { class: "add" });
  const input = el("input", { type: "text", maxlength: "60", placeholder: isRequired ? "Name of person who joined" : "Mark Required first", id: `${name}-who` });
  input.disabled = !isRequired;
  const button = el("button", { type: "button", text: "Add" });
  button.disabled = !isRequired;
  const submit = async () => {
    const who = input.value.trim();
    if (!who) return;
    if (await save(incident, key, "joined", who)) input.value = "";
  };
  button.addEventListener("click", submit);
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); submit(); } });
  addRow.appendChild(input);
  addRow.appendChild(button);
  block.appendChild(addRow);
  return block;
}

const STATES = ["In Progress", "On Hold", "Resolved"];
let stateFilter = "All";
let lastData = { incidents: [], swat: {} };

function stateClass(state) {
  return state === "On Hold" ? "on-hold" : state === "Resolved" ? "resolved" : "";
}

function renderFilters() {
  const bar = document.getElementById("filters");
  bar.replaceChildren();
  const counts = { All: lastData.incidents.length };
  for (const s of STATES) counts[s] = lastData.incidents.filter((i) => i.state === s).length;
  for (const s of ["All", ...STATES]) {
    const button = el("button", { type: "button", class: s === stateFilter ? "active" : "", text: `${s} (${counts[s]})` });
    button.addEventListener("click", () => { stateFilter = s; render(lastData); });
    bar.appendChild(button);
  }
}

function render(data) {
  lastData = data;
  renderFilters();
  const grid = document.getElementById("grid");
  grid.replaceChildren();
  if (!data.incidents.length) {
    grid.appendChild(el("div", { class: "empty", text: "No incidents in incidents.json yet." }));
    return;
  }
  const shown = data.incidents.filter((i) => stateFilter === "All" || i.state === stateFilter);
  if (!shown.length) {
    grid.appendChild(el("div", { class: "empty", text: `No ${stateFilter} incidents.` }));
    return;
  }
  for (const inc of shown) {
    const swat = (data.swat && data.swat[inc.number]) || {};
    const state = inc.state || "In Progress";
    const card = el("div", { class: "card" }, [
      el("h2", {}, [el("span", { text: inc.number }), el("span", { class: "pri", text: inc.priority || "-" })]),
      el("div", { class: "row" }, [
        el("span", { class: "state " + stateClass(state), text: state + (inc.state_at ? " since " + inc.state_at : "") }),
      ]),
      el("div", { class: "text", text: inc.text }),
      el("div", { class: "text", text: inc.text }),
      el("a", { class: "details", href: "/incident/" + encodeURIComponent(inc.number), target: "_blank", rel: "noopener", text: "Open details & notes (new page)" }),
    ]);
    for (const [key, label] of TEAMS) {
      card.appendChild(teamBlock(inc.number, key, label, swat[key] || {}));
    }
    grid.appendChild(card);
  }
}

async function load() {
  try {
    const r = await fetch("/api/incidents", { cache: "no-store" });
    render(await r.json());
    document.getElementById("updated").textContent = "Updated " + new Date().toLocaleTimeString();
  } catch (e) {
    setMsg("Cannot reach the SWAT board server. Check that it is running.");
  }
}
load();
setInterval(load, 10000);
</script>
</body></html>
"""

NOTES_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SWAT details and notes</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; background: #f3f6fb; margin: 0; padding: 20px; color: #1b2b44; }
  .wrap { max-width: 960px; margin: 0 auto; }
  a { color: #1e4fb8; }
  h1 { font-size: 1.4rem; margin: 6px 0 4px; }
  h2 { font-size: 1.05rem; margin: 22px 0 8px; }
  .sub { color: #56657a; margin-bottom: 14px; font-size: 0.92rem; }
  .bar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; margin-bottom: 10px; }
  .bar input { padding: 8px 10px; border: 1px solid #c5d2e4; border-radius: 8px; min-width: 220px; }
  .btn { padding: 8px 14px; border: 0; border-radius: 8px; background: #1e6fd9; color: #fff; cursor: pointer; text-decoration: none; }
  .btn.secondary { background: #e7efff; color: #1e4fb8; }
  .qgrid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 16px; }
  .qgrid label { display: block; font-size: 0.88rem; color: #4a5a70; margin-bottom: 3px; }
  .qgrid input, textarea { width: 100%; box-sizing: border-box; padding: 8px 10px; border: 1px solid #c5d2e4; border-radius: 8px; background: #fff; font: inherit; }
  textarea.notes { min-height: 380px; font: 15px Consolas, "Courier New", monospace; line-height: 1.5; border-radius: 12px; }
  .status { font-size: 0.88rem; color: #56657a; min-height: 1.3em; margin-top: 8px; }
  .status.err { color: #b42318; }
  @media (max-width: 640px) { .qgrid { grid-template-columns: 1fr; } }
</style></head>
<body><div class="wrap">
  <a href="/">&larr; Back to the SWAT board</a>
  <h1 id="title">SWAT details and notes</h1>
  <div class="sub">Answer the intake questions and write what is happening. Each new line starts with the time on this machine. Notes are saved on the computer running the SWAT board.</div>
  <div class="bar">
    <input id="name" placeholder="Your name (required to save)" maxlength="60">
    <button id="save" type="button" class="btn">Save now</button>
    <button id="reload" type="button" class="btn secondary">Load latest</button>
    <a id="download" class="btn secondary" href="#">Download Excel</a>
  </div>
  <h2>Intake questions</h2>
  <div class="qgrid" id="questions"></div>
  <h2>RCA</h2>
  <textarea id="rca" rows="3"></textarea>
  <h2>History of troubleshooting</h2>
  <div class="sub">Each new line starts with the time on this machine.</div>
  <textarea id="notes" class="notes" spellcheck="false" placeholder="Start typing here..."></textarea>
  <div class="status" id="status"></div>
</div>
<script>
const incident = decodeURIComponent(location.pathname.split("/")[2]);
document.getElementById("title").textContent = "SWAT details and notes: " + incident;
document.getElementById("download").href = "/incident/" + encodeURIComponent(incident) + "/export.xlsx";
const nameBox = document.getElementById("name");
const notesBox = document.getElementById("notes");
const rcaBox = document.getElementById("rca");
const questionsBox = document.getElementById("questions");
const statusBox = document.getElementById("status");
nameBox.value = localStorage.getItem("swat-name") || "";
nameBox.addEventListener("change", () => localStorage.setItem("swat-name", nameBox.value.trim()));

const TIME_KEYS = new Set(["issue_start", "toc_received", "toc_joined", "toc_closed"]);
let version = 0;
let dirty = false;
let timer = null;
let built = false;

function two(n) { return String(n).padStart(2, "0"); }
function nowTime() { const d = new Date(); return `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`; }
function setStatus(text, err) { statusBox.textContent = text; statusBox.className = "status" + (err ? " err" : ""); }

function markDirty() {
  dirty = true;
  clearTimeout(timer);
  timer = setTimeout(saveNotes, 2000);
}

// When someone starts typing on a line, put this machine's current time at the start of that line.
notesBox.addEventListener("input", () => {
  const pos = notesBox.selectionStart;
  const lineStart = notesBox.value.lastIndexOf("\\n", pos - 1) + 1;
  let lineEnd = notesBox.value.indexOf("\\n", pos);
  if (lineEnd === -1) lineEnd = notesBox.value.length;
  const line = notesBox.value.slice(lineStart, lineEnd);
  if (line.trim() && !/^\\[\\d{2}:\\d{2}:\\d{2}\\] /.test(line)) {
    const stamp = `[${nowTime()}] `;
    notesBox.value = notesBox.value.slice(0, lineStart) + stamp + notesBox.value.slice(lineStart);
    notesBox.setSelectionRange(pos + stamp.length, pos + stamp.length);
  }
  markDirty();
});
rcaBox.addEventListener("input", markDirty);

function buildQuestions(questions, answers, defaults) {
  questionsBox.replaceChildren();
  for (const [key, label] of questions) {
    const id = "q-" + key;
    const wrap = document.createElement("div");
    const lab = document.createElement("label");
    lab.setAttribute("for", id);
    lab.textContent = label;
    const input = document.createElement("input");
    input.id = id;
    input.type = TIME_KEYS.has(key) ? "datetime-local" : "text";
    input.maxLength = 1000;
    input.value = answers[key] || defaults[key] || "";
    input.addEventListener("input", markDirty);
    wrap.appendChild(lab);
    wrap.appendChild(input);
    questionsBox.appendChild(wrap);
  }
}

function collectAnswers() {
  const out = {};
  for (const input of questionsBox.querySelectorAll("input")) {
    out[input.id.slice(2)] = input.value;
  }
  return out;
}

async function loadLatest(force) {
  const r = await fetch("/api/notes?incident=" + encodeURIComponent(incident), { cache: "no-store" });
  const d = await r.json();
  if (force || !dirty) {
    version = d.version;
    if (force || !built) {
      buildQuestions(d.questions, d.answers, d.defaults);
      built = true;
    }
    notesBox.value = d.text;
    rcaBox.value = d.rca || "";
    dirty = false;
    setStatus(d.updated_at ? `Last saved ${d.updated_at} by ${d.updated_by}` : "Nothing saved yet.");
  }
}

async function saveNotes() {
  clearTimeout(timer);
  const name = nameBox.value.trim();
  if (!name) { setStatus("Enter your name above to save.", true); nameBox.focus(); return; }
  localStorage.setItem("swat-name", name);
  setStatus("Saving...");
  const r = await fetch("/api/notes", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ incident, text: notesBox.value, base_version: version, name,
                           answers: collectAnswers(), rca: rcaBox.value }),
  });
  const body = await r.json().catch(() => ({}));
  if (r.status === 409) {
    setStatus((body.error || "Someone else saved first.") + " Your text is kept. Use 'Load latest' to see their version.", true);
    return;
  }
  if (!r.ok) { setStatus(body.error || "Could not save.", true); return; }
  version = body.version;
  dirty = false;
  setStatus(`Saved at ${nowTime()} by ${body.updated_by}`);
}

document.getElementById("save").addEventListener("click", saveNotes);
document.getElementById("reload").addEventListener("click", () => loadLatest(true));
loadLatest(true);
setInterval(() => { if (!dirty) loadLatest(false); }, 15000);
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, content_type="application/json; charset=utf-8", headers=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/":
            self._send(200, BOARD_PAGE, "text/html; charset=utf-8")
        elif path.startswith("/incident/") and path.endswith("/export.xlsx"):
            incident = path[len("/incident/"):-len("/export.xlsx")]
            if not INCIDENT_ID.match(incident):
                self._send(404, json.dumps({"error": "not found"}))
                return
            try:
                data = build_intake_workbook(incident)
            except ImportError:
                self._send(500, json.dumps({"error": "The Excel export needs openpyxl. Run: pip install openpyxl"}))
                return
            self._send(200, data, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                       {"Content-Disposition": f'attachment; filename="{export_filename(incident)}"'})
        elif path.startswith("/incident/"):
            incident = path[len("/incident/"):]
            if not INCIDENT_ID.match(incident):
                self._send(404, json.dumps({"error": "not found"}))
                return
            self._send(200, NOTES_PAGE, "text/html; charset=utf-8")
        elif path == "/api/incidents":
            payload = {"incidents": incidents_for_page(), "swat": _read_json(STORAGE_STATUS)}
            self._send(200, json.dumps(payload))
        elif path == "/api/notes":
            incident = (parse_qs(url.query).get("incident") or [""])[0]
            if not INCIDENT_ID.match(incident):
                self._send(400, json.dumps({"error": "bad incident"}))
                return
            payload = read_notes(incident)
            payload["questions"] = INTAKE_QUESTIONS
            incident_data = _read_json(STORAGE_INCIDENTS).get(incident, {})
            payload["defaults"] = {"priority": incident_data.get("priority") or "", "incident": incident}
            self._send(200, json.dumps(payload))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            body = self._read_body()
        except (ValueError, json.JSONDecodeError):
            self._send(400, json.dumps({"error": "bad request"}))
            return

        if path == "/api/set":
            incident = str(body.get("incident", "")).strip()
            team = str(body.get("team", "")).strip()
            field = str(body.get("field", "")).strip()
            value = str(body.get("value", "")).strip()
            name = str(body.get("name", "")).strip()
            if not INCIDENT_ID.match(incident) or team not in TEAMS or not name or len(name) > 60:
                self._send(400, json.dumps({"error": "Pick a team, and enter your name."}))
                return
            if field == "required" and value in REQUIRED_VALUES:
                pass
            elif field == "joined" and 1 <= len(value) <= 60:
                pass
            else:
                self._send(400, json.dumps({"error": "Choose Required or Not required, or enter the name of the person who joined."}))
                return
            try:
                saved, message = set_choice(incident, team, field, value, name)
            except TimeoutError as exc:
                self._send(503, json.dumps({"error": str(exc)}))
                return
            self._send(200 if saved else 409, json.dumps({"ok": saved, "error": None if saved else message, "message": message}))

        elif path == "/api/notes":
            incident = str(body.get("incident", "")).strip()
            text = str(body.get("text", ""))
            name = str(body.get("name", "")).strip()
            try:
                base_version = int(body.get("base_version", -1))
            except (TypeError, ValueError):
                base_version = -1
            answers = body.get("answers")
            if answers is not None:
                if not isinstance(answers, dict):
                    self._send(400, json.dumps({"error": "answers must be a list of question answers."}))
                    return
                answers = {k: str(v)[:1000] for k, v in answers.items() if k in INTAKE_KEYS}
            rca = body.get("rca")
            rca = None if rca is None else str(rca)[:20000]
            if not INCIDENT_ID.match(incident) or not name or len(name) > 60 or len(text) > MAX_NOTES_CHARS:
                self._send(400, json.dumps({"error": "Enter your name. Notes must be under 200,000 characters."}))
                return
            try:
                saved, current = save_notes(incident, text, base_version, name, answers, rca)
            except TimeoutError as exc:
                self._send(503, json.dumps({"error": str(exc)}))
                return
            if saved:
                self._send(200, json.dumps(current))
            else:
                self._send(409, json.dumps({"error": "Someone else saved these notes first.", **current}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, fmt, *args):
        print(f"[{datetime.now():%H:%M:%S}] {self.address_string()} {fmt % args}")


def start_in_background(host: str = "0.0.0.0", port: int = 8080):
    """Start the board in a background thread of the calling program (used by the monitor)."""
    server = ThreadingHTTPServer((host, port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True, name="swat-board").start()
    return server


if __name__ == "__main__":
    main()
