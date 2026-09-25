# Cablecar — personal, unsandboxed, local build (see docs/design.md).

BUNDLE := Cablecar.app

.PHONY: run test app clean

# Run straight from SwiftPM (window appears via the activation-policy shim).
run:
	swift run Cablecar

test:
	swift test

# Assemble a minimal .app bundle (dock icon, proper app name) and ad-hoc sign it.
app:
	swift build -c release
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	cp .build/release/Cablecar $(BUNDLE)/Contents/MacOS/Cablecar
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE) — open with: open $(BUNDLE)"

clean:
	rm -rf .build $(BUNDLE)
