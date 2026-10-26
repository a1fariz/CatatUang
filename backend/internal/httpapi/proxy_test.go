package httpapi

import (
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestClientIPTrustBoundary(t *testing.T) {
	cases := []struct {
		name, peer, header, want string
		trusted                  bool
	}{
		{"direct spoof", "192.0.2.10:1234", "198.51.100.20", "192.0.2.10", false},
		{"trusted proxy", "172.30.251.2:1234", "198.51.100.20", "198.51.100.20", true},
		{"other container spoof", "172.30.251.3:1234", "198.51.100.20", "172.30.251.3", true},
		{"forwarded list rejected", "172.30.251.2:1234", "198.51.100.20, 192.0.2.1", "172.30.251.2", true},
		{"invalid rejected", "172.30.251.2:1234", "garbage", "172.30.251.2", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			a := &API{}
			if tc.trusted {
				a.trustedProxies = []netip.Prefix{netip.MustParsePrefix("172.30.251.2/32")}
			}
			r := httptest.NewRequest("POST", "/v1/auth/login", nil)
			r.RemoteAddr = tc.peer
			r.Header.Set("X-Forwarded-For", tc.header)
			if got := a.clientIP(r); got != tc.want {
				t.Fatalf("got %s", got)
			}
			r.Header.Add("X-Forwarded-For", "203.0.113.1")
			if got := a.clientIP(r); tc.peer == "172.30.251.2:1234" && got != "172.30.251.2" {
				t.Fatal("duplicate forwarded headers accepted")
			}
		})
	}
}
