.PHONY: fetch build bundle install run clean cert models test test-integration

fetch:
	scripts/fetch-whisper.sh

build: fetch
	swift build

# XCTest needs Xcode and the Command Line Tools' Testing.framework is missing its
# interop dylib, so the suite is a plain executable target instead of `swift test`.
test: fetch
	swift run DiktaTests

# Drives the real binary end to end; needs Screen Recording permission.
test-integration: fetch
	DIKTA_INTEGRATION=1 Tests/Integration/cli-flow.sh

bundle: fetch
	scripts/bundle.sh

install: bundle
	ditto build/Dikta.app /Applications/Dikta.app
	@echo "Installed /Applications/Dikta.app"

run: build
	./.build/debug/Dikta

cert:
	scripts/make-cert.sh

models:
	mkdir -p "$$HOME/Library/Application Support/Dikta/models"
	curl -fL -o "$$HOME/Library/Application Support/Dikta/models/ggml-large-v3-turbo-q5_0.bin" \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

clean:
	rm -rf .build build
