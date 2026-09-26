#!/usr/bin/env python3

from pathlib import Path

source = Path(
    "src/product/SpringBoardControlHost.mm"
).read_text()

tests = []


def record(name: str, passed: bool) -> None:
    tests.append((name, passed))
    print(("PASS " if passed else "FAIL ") + name)


record(
    "owner is not a synchronous value member",
    "ProductControlOwner _owner;" not in source
    and "std::shared_ptr<" in source
    and "ProductControlOwner>" in source,
)

worker_call = source.find(
    "dispatch_async(\n"
    "        ProductOwnerInitializationQueue()"
)
constructor = source.find(
    "std::make_shared<"
)
publish = source.find(
    "dispatch_async(\n"
    "                    dispatch_get_main_queue()",
    constructor,
)

record(
    "owner construction scheduled off main",
    worker_call >= 0
    and constructor > worker_call
    and publish > constructor,
)

record(
    "control UI readiness gate",
    "_floatingButton.enabled = NO;" in source
    and "if (!_ownerReady ||" in source
    and "strongSelf->_ownerReady =" in source
    and ".enabled = YES;" in source,
)

record(
    "owner publication returns to main thread",
    publish >= 0
    and "strongSelf->_owner =" in source[publish:],
)

record(
    "shared owner lifetime retained by overlay",
    "std::shared_ptr<" in source
    and "auto owner = _owner;" in source
    and "owner.get()" in source,
)

record(
    "repeated start and initialization are one-shot",
    "if (gOverlayWindow != nil)" in source
    and "if (_ownerInitializationStarted ||" in source
    and "dispatch_once(" in source,
)

record(
    "no synchronous main to worker wait",
    "dispatch_sync(" not in source,
)

failures = sum(
    1 for _, passed in tests if not passed
)

print(
    f"SpringBoard storage decoupling tests run: "
    f"{len(tests)}, failures: {failures}"
)

if failures:
    raise SystemExit(1)

print(
    "SPRINGBOARD_MAIN_THREAD_STORAGE_RECOVERY=ABSENT"
)
print(
    "PRODUCT_OWNER_BACKGROUND_INITIALIZATION=PASS"
)
print(
    "CONTROL_UI_OWNER_READINESS_GATE=PASS"
)
print(
    "PRODUCT_OWNER_LIFETIME=PASS"
)
