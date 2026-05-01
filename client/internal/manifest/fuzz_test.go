// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

package manifest

import "testing"

// FuzzParse: any byte sequence going into Parse() must either
// produce a *Manifest or an error — never panic.
func FuzzParse(f *testing.F) {
	f.Add([]byte(`{"schema_version":1,"release_id":"a/linux-x86_64/1.0.0","software":"a","os":"linux","arch":"x86_64","os_versions":["1"],"version":"1.0.0","published_at":"2026-01-01T00:00:00Z","blob":{"sha256":"` + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" + `","size":1,"url":"/v1/blobs/x"},"patches_in":[],"patches_out":[],"channels":[],"classifications":[],"deprecated":false,"uncollectable":false}`))
	f.Add([]byte(`{"schema_version":2}`))
	f.Add([]byte(``))
	f.Add([]byte(`{`))
	f.Add([]byte(`null`))
	f.Add([]byte(`[]`))

	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = Parse(data)
	})
}

// FuzzVerify: hex-decoding garbage signatures and pubkeys must
// return an error, never panic.
func FuzzVerify(f *testing.F) {
	good := []byte(`{"schema_version":1}`)
	f.Add(good, "0102", "abcd")
	f.Add(good, "", "")
	f.Add([]byte{}, "ff", "ff")

	f.Fuzz(func(t *testing.T, data []byte, sigHex, pubHex string) {
		_ = Verify(data, sigHex, pubHex)
	})
}
