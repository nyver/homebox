package httpapi_test

import (
	"context"
	"net/http"
	"testing"
)

func TestShareDeviceDirectoryReturnsOnlyActivePublicKeys(t *testing.T) {
	s := startTestServer(t)
	member, err := s.auth.CreateUser(context.Background(), "member", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	memberDeviceID := "77777777-7777-7777-7777-777777777777"
	loginDevice(t, s, "member", memberDeviceID)
	admin := loginDevice(t, s, "admin", "88888888-8888-8888-8888-888888888888")
	resp, raw := s.doRaw(t, http.MethodGet, "/api/v1/users/"+member.ID+"/share-devices", nil, admin["accessToken"].(string))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("share device directory status=%d body=%s", resp.StatusCode, raw)
	}
	devices := decodeArray(t, raw)
	if len(devices) != 1 || devices[0]["id"] != memberDeviceID || devices[0]["publicKey"] == "" {
		t.Fatalf("share device directory=%#v", devices)
	}
	if _, exposedName := devices[0]["name"]; exposedName {
		t.Fatalf("share device directory exposed a device name: %#v", devices[0])
	}
}
