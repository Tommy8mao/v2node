package panel

import (
	"encoding/json"
	"testing"
)

func TestPaddingSchemeAcceptsAnyTLSList(t *testing.T) {
	var node CommonNode
	if err := json.Unmarshal([]byte(`{"padding_scheme":["stop=8","0=8-16"]}`), &node); err != nil {
		t.Fatal(err)
	}
	if len(node.PaddingScheme) != 2 || node.PaddingScheme[0] != "stop=8" {
		t.Fatalf("unexpected padding scheme: %#v", node.PaddingScheme)
	}
}

func TestPaddingSchemeToleratesLegacyNextV1Object(t *testing.T) {
	var node CommonNode
	if err := json.Unmarshal([]byte(`{"protocol":"next-v1","padding_scheme":{"min":0,"max":64}}`), &node); err != nil {
		t.Fatal(err)
	}
	if node.PaddingScheme != nil {
		t.Fatalf("Next-V1 client padding leaked into backend config: %#v", node.PaddingScheme)
	}
}

func TestPaddingSchemeRejectsUnknownObject(t *testing.T) {
	var node CommonNode
	if err := json.Unmarshal([]byte(`{"padding_scheme":{"unexpected":true}}`), &node); err == nil {
		t.Fatal("expected invalid padding object to fail")
	}
}

func TestNormalizeAPIHost(t *testing.T) {
	if got := NormalizeAPIHost("  https://panel.example///  "); got != "https://panel.example" {
		t.Fatalf("NormalizeAPIHost() = %q", got)
	}
}
