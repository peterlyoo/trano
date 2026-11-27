package main

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

const historyID = "22222222-2222-4222-8222-222222222222"

func historyFixture(t *testing.T, reports ...string) (*Runtime, *[][]string) {
	t.Helper()
	r := &Runtime{root: t.TempDir()}
	if err := r.save(State{SchemaVersion: 1, Sessions: []Session{{ID: historyID, PID: 42, Alive: true}}}); err != nil {
		t.Fatal(err)
	}
	calls := [][]string{}
	r.historyExecute = func(args ...string) (string, error) {
		calls = append(calls, append([]string(nil), args...))
		if args[0] == "display-message" {
			if len(reports) == 0 {
				t.Fatal("unexpected metadata query")
			}
			value := reports[0]
			reports = reports[1:]
			return value, nil
		}
		return "", nil
	}
	return r, &calls
}
func historyRequest(method string, params map[string]any) Request {
	p := map[string]json.RawMessage{}
	for k, v := range params {
		p[k], _ = json.Marshal(v)
	}
	return Request{APIVersion: 1, Method: method, Params: p}
}
func historyParams() map[string]any {
	return map[string]any{"id": historyID, "expectedPID": 42, "lines": 3}
}
func historyResult(t *testing.T, r Response) HistoryResponse {
	t.Helper()
	if r.Error != "" {
		t.Fatalf("history route failed: %s", r.Error)
	}
	v, ok := r.Result.(HistoryResponse)
	if !ok || v.HistoryProtocol != 1 || v.ID != historyID {
		t.Fatalf("invalid result %#v", r.Result)
	}
	return v
}
func historyEffects(calls [][]string) [][]string {
	out := [][]string{}
	for _, c := range calls {
		if c[0] != "display-message" {
			out = append(out, c)
		}
	}
	return out
}

// Implements: FR-REMOTE-INPUT-1, FR-REMOTE-INPUT-2
func TestRemoteHistoryScrollUsesOnlyOwnedCopyModeCommands(t *testing.T) {
	r, calls := historyFixture(t, "42\t0\t\t\n", "42\t1\t3\tcopy-mode\n")
	v := historyResult(t, r.Route(historyRequest("panes.history.scroll", historyParams())))
	want := [][]string{{"copy-mode", "-t", historyID + ":0.0"}, {"send-keys", "-X", "-N", "3", "-t", historyID + ":0.0", "scroll-up"}}
	if !v.Matched || v.InputReady || v.PID != 42 || !reflect.DeepEqual(historyEffects(*calls), want) {
		t.Fatalf("bad result %#v calls %#v", v, *calls)
	}
}

// Implements: FR-REMOTE-INPUT-2
func TestRemoteHistoryCancelRequiresFreshPostCommandReadiness(t *testing.T) {
	for _, post := range []string{"42\t0\t\t\n", "43\t0\t\t\n", "42\t1\t3\tview-mode\n", "42\t1\t3\tcopy-mode\n"} {
		r, calls := historyFixture(t, "42\t1\t3\tcopy-mode\n", post)
		v := historyResult(t, r.Route(historyRequest("panes.history.cancel", map[string]any{"id": historyID, "expectedPID": 42})))
		if v.InputReady != strings.HasPrefix(post, "42\t0") || len(historyEffects(*calls)) != 1 {
			t.Fatalf("bad post %q %#v %#v", post, v, *calls)
		}
	}
}

// Implements: FR-REMOTE-INPUT-2
func TestRemoteHistoryDownAndAlreadyLiveNeverSendProviderArrows(t *testing.T) {
	r, calls := historyFixture(t, "42\t1\t2\tcopy-mode\n", "42\t0\t\t\n")
	p := historyParams()
	p["lines"] = -3
	v := historyResult(t, r.Route(historyRequest("panes.history.scroll", p)))
	if !v.InputReady || !reflect.DeepEqual(historyEffects(*calls), [][]string{{"send-keys", "-X", "-t", historyID + ":0.0", "cancel"}}) {
		t.Fatalf("bad bottom result %#v %#v", v, *calls)
	}
	for _, report := range []string{"42\t0\t\t\n", "42\t1\t3\tview-mode\n"} {
		r, calls := historyFixture(t, report)
		v := historyResult(t, r.Route(historyRequest("panes.history.cancel", map[string]any{"id": historyID, "expectedPID": 42})))
		if v.InputReady != strings.HasPrefix(report, "42\t0") || len(historyEffects(*calls)) != 0 {
			t.Fatalf("unsafe no-op %#v %#v", v, *calls)
		}
	}
}

// Implements: FR-REMOTE-INPUT-2
func TestRemoteHistoryWrongStoredOrFreshPIDNeverMutates(t *testing.T) {
	for _, expected := range []int{42, 77} {
		r, calls := historyFixture(t, "43\t1\t3\tcopy-mode\n")
		p := historyParams()
		p["expectedPID"] = expected
		v := historyResult(t, r.Route(historyRequest("panes.history.scroll", p)))
		if v.Matched || v.InputReady || len(historyEffects(*calls)) != 0 {
			t.Fatalf("unsafe mismatch %#v %#v", v, *calls)
		}
		if expected == 77 && len(*calls) != 0 {
			t.Fatal("stored mismatch queried backend")
		}
	}
}

// Implements: FR-REMOTE-INPUT-2
func TestRemoteHistoryStrictRoutesRejectInvalidRequests(t *testing.T) {
	variants := []map[string]any{}
	for _, pid := range []any{nil, 0, -1, 2147483648, 42.5, "42", true} {
		p := historyParams()
		p["expectedPID"] = pid
		variants = append(variants, p)
	}
	for _, lines := range []any{nil, 1001, -1001, 1.5, "3", false} {
		p := historyParams()
		p["lines"] = lines
		variants = append(variants, p)
	}
	for _, field := range []string{"lines", "expectedPID"} {
		p := historyParams()
		delete(p, field)
		variants = append(variants, p)
	}
	p := historyParams()
	p["id"] = "-t ; send-keys"
	variants = append(variants, p)
	p = historyParams()
	p["extra"] = "provider input"
	variants = append(variants, p)
	for _, p := range variants {
		r, calls := historyFixture(t)
		if v := r.Route(historyRequest("panes.history.scroll", p)); v.Error == "" || len(*calls) != 0 {
			t.Fatalf("invalid accepted %#v %#v %#v", p, v, *calls)
		}
	}
}

// Implements: FR-REMOTE-INPUT-2
func TestRemoteHistoryMalformedMetadataAndUnknownOwnerNeverMutate(t *testing.T) {
	for _, report := range []string{"", "42\t2\t0\tcopy-mode", "42\t1\t-1\tcopy-mode", "42\t1\tNaN\tcopy-mode", "0\t0\t\t", "42\t0\t\t\textra", strings.Repeat("x", 513)} {
		r, calls := historyFixture(t, report)
		v := r.Route(historyRequest("panes.history.scroll", historyParams()))
		if v.Error == "" || len(historyEffects(*calls)) != 0 {
			t.Fatalf("bad metadata %q %#v %#v", report, v, *calls)
		}
	}
	r, calls := historyFixture(t)
	p := historyParams()
	p["id"] = "11111111-1111-4111-8111-111111111111"
	if v := r.Route(historyRequest("panes.history.scroll", p)); v.Error == "" || len(*calls) != 0 {
		t.Fatal("unknown owner queried")
	}
}

// Implements: FR-REMOTE-INPUT-2
func TestRemoteHistoryCommandFailureCannotAuthorizeInput(t *testing.T) {
	r, _ := historyFixture(t)
	r.historyExecute = func(...string) (string, error) { return "", errors.New("fixture failure") }
	if v := r.Route(historyRequest("panes.history.cancel", map[string]any{"id": historyID, "expectedPID": 42})); v.Error == "" {
		t.Fatalf("failure authorized %#v", v)
	}
}

// Implements: FR-REMOTE-INPUT-2
func TestRemoteHistoryResponseWireSchemaKeepsIdentityAndReadinessFields(t *testing.T) {
	r, _ := historyFixture(t, "42\t0\t\t\n")
	response := r.Route(historyRequest("panes.history.cancel", map[string]any{"id": historyID, "expectedPID": 42}))
	data, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"apiVersion":1,"result":{"historyProtocol":1,"id":"22222222-2222-4222-8222-222222222222","pid":42,"matched":true,"inputReady":true}}`
	if string(data) != want {
		t.Fatalf("wire contract changed: %s", data)
	}
}
