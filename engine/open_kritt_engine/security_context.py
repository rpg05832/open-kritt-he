import logging

from .incremental_review import prepare_incremental_review
from .security_preflight import write_preflight


def prepare_security_context(root, scan, output_root=None):
    configuration = scan.get("configuration") or {}
    if not isinstance(configuration, dict):
        return
    if not configuration.get("security_preflight") and configuration.get("scan_mode") != "changes":
        return
    try:
        changes = prepare_incremental_review(root, scan, output_root=output_root)
        # scan_kind: "security" (default), "quality" or "both".
        kind = configuration.get("scan_kind") if configuration.get("scan_kind") in ("quality", "both") else "security"
        return write_preflight(
            root,
            scan["id"],
            output_root=output_root,
            dependency_audit=configuration.get("dependency_audit") is True,
            incremental=changes,
            scan_kind=kind,
        )
    except (OSError, ValueError):
        logging.getLogger(__name__).exception("Local security context unavailable")
