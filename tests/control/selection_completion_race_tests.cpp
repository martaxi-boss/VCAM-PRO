#include "SelectionCompletionGate.h"

#include <cstdint>
#include <functional>
#include <iostream>
#include <string>

namespace {

using vcam::control::SelectionCompletionGate;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr \
                << "CHECK failed at " \
                << __FILE__ << ":" \
                << __LINE__ << ": " \
                << #condition \
                << std::endl; \
            return false; \
        } \
    } while (false)

struct FakePersistentMedia {
    std::string current = "existing";
    int stageCalls = 0;
    int commits = 0;
};

bool Complete(
    SelectionCompletionGate& gate,
    std::uint64_t token,
    const std::string& candidate,
    bool stagingSucceeds,
    FakePersistentMedia* state) {
    if (state == nullptr ||
        !gate.claimFileCompletion(token)) {
        return false;
    }

    ++state->stageCalls;

    if (!stagingSucceeds) {
        return false;
    }

    state->current = candidate;
    ++state->commits;
    return true;
}

bool TestARequestBegins() {
    SelectionCompletionGate gate;
    const auto a = gate.beginRequest();

    CHECK(a != 0);
    CHECK(gate.currentRequestToken() == a);
    return true;
}

bool TestBInvalidatesA() {
    SelectionCompletionGate gate;
    const auto a = gate.beginRequest();
    CHECK(gate.accept(a));

    const auto b = gate.beginRequest();

    CHECK(b != a);
    CHECK(gate.currentRequestToken() == b);
    return true;
}

bool TestLateARejectedBeforeMutation() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;

    const auto a = gate.beginRequest();
    CHECK(gate.accept(a));

    const auto b = gate.beginRequest();
    CHECK(gate.accept(b));

    CHECK(!Complete(
        gate,
        a,
        "A",
        true,
        &state));
    CHECK(state.stageCalls == 0);
    CHECK(state.commits == 0);
    CHECK(state.current == "existing");
    return true;
}

bool TestBAcceptedExactlyOnce() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;

    const auto b = gate.beginRequest();
    CHECK(gate.accept(b));

    CHECK(Complete(
        gate,
        b,
        "B",
        true,
        &state));
    CHECK(state.stageCalls == 1);
    CHECK(state.commits == 1);
    CHECK(state.current == "B");
    return true;
}

bool TestDuplicateBRejected() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;

    const auto b = gate.beginRequest();
    CHECK(gate.accept(b));

    CHECK(Complete(
        gate,
        b,
        "B",
        true,
        &state));
    CHECK(!Complete(
        gate,
        b,
        "B-duplicate",
        true,
        &state));

    CHECK(state.stageCalls == 1);
    CHECK(state.commits == 1);
    CHECK(state.current == "B");
    return true;
}

bool TestCancellationDoesNotReviveA() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;

    const auto a = gate.beginRequest();
    CHECK(gate.accept(a));

    const auto b = gate.beginRequest();
    CHECK(gate.accept(b));

    // Request B is cancelled after its picker completion.
    // No file-representation completion is claimed for B.
    CHECK(!Complete(
        gate,
        a,
        "A",
        true,
        &state));

    CHECK(state.stageCalls == 0);
    CHECK(state.commits == 0);
    CHECK(state.current == "existing");
    return true;
}

bool TestExistingMediaUnaffectedByStaleA() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;
    state.current = "selected-before-race";

    const auto a = gate.beginRequest();
    CHECK(gate.accept(a));

    const auto b = gate.beginRequest();
    CHECK(gate.accept(b));

    CHECK(!Complete(
        gate,
        a,
        "stale-A",
        true,
        &state));

    CHECK(
        state.current ==
        "selected-before-race");
    CHECK(state.stageCalls == 0);
    CHECK(state.commits == 0);
    return true;
}

bool TestFailedNewerDoesNotReviveOlder() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;
    state.current = "existing";

    const auto a = gate.beginRequest();
    CHECK(gate.accept(a));

    const auto b = gate.beginRequest();
    CHECK(gate.accept(b));

    CHECK(!Complete(
        gate,
        b,
        "B",
        false,
        &state));

    CHECK(state.stageCalls == 1);
    CHECK(state.commits == 0);
    CHECK(state.current == "existing");

    CHECK(!Complete(
        gate,
        a,
        "A",
        true,
        &state));

    CHECK(state.stageCalls == 1);
    CHECK(state.commits == 0);
    CHECK(state.current == "existing");
    return true;
}

bool TestCompletionRequiresAcceptedPicker() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;

    const auto token =
        gate.beginRequest();

    CHECK(!Complete(
        gate,
        token,
        "candidate",
        true,
        &state));

    CHECK(state.stageCalls == 0);
    CHECK(state.commits == 0);
    return true;
}

bool TestNewestRequestWinsSequence() {
    SelectionCompletionGate gate;
    FakePersistentMedia state;

    const auto a = gate.beginRequest();
    CHECK(gate.accept(a));

    const auto b = gate.beginRequest();
    CHECK(gate.accept(b));

    CHECK(!Complete(
        gate,
        a,
        "A",
        true,
        &state));

    CHECK(Complete(
        gate,
        b,
        "B",
        true,
        &state));

    CHECK(!Complete(
        gate,
        b,
        "B-duplicate",
        true,
        &state));

    CHECK(state.stageCalls == 1);
    CHECK(state.commits == 1);
    CHECK(state.current == "B");
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;

    const bool passed = test();

    std::cout
        << (passed ? "PASS " : "FAIL ")
        << name
        << std::endl;

    if (!passed) {
        ++gFailures;
    }
}

}  // namespace

int main() {
    Run("A request begins", TestARequestBegins);
    Run("B invalidates A", TestBInvalidatesA);
    Run(
        "late A rejected before mutation",
        TestLateARejectedBeforeMutation);
    Run(
        "B accepted exactly once",
        TestBAcceptedExactlyOnce);
    Run(
        "duplicate B rejected",
        TestDuplicateBRejected);
    Run(
        "cancellation does not revive A",
        TestCancellationDoesNotReviveA);
    Run(
        "existing media unaffected by stale A",
        TestExistingMediaUnaffectedByStaleA);
    Run(
        "failed newer does not revive older",
        TestFailedNewerDoesNotReviveOlder);
    Run(
        "completion requires accepted picker",
        TestCompletionRequiresAcceptedPicker);
    Run(
        "newest request wins sequence",
        TestNewestRequestWinsSequence);

    std::cout
        << "Selection race tests run: "
        << gTests
        << ", failures: "
        << gFailures
        << std::endl;

    return gFailures == 0 ? 0 : 1;
}
