# JXLSwift Makefile

.PHONY: all build test clean install install-man man help

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man/man1

all: build

## Build the project
build:
	@echo "Building JXLSwift..."
	swift build -c release

## Run all tests
test:
	@echo "Running tests..."
	swift test

## Generate man pages
man:
	@echo "Generating man pages..."
	@mkdir -p Documentation/man
	swift package --allow-writing-to-directory Documentation/man \
		generate-manual --multi-page --output-directory Documentation/man

## Install jxl-tool binary
install: build
	@echo "Installing jxl-tool to $(BINDIR)..."
	@mkdir -p $(BINDIR)
	@install -m 755 .build/release/jxl-tool $(BINDIR)/jxl-tool
	@echo "jxl-tool installed to $(BINDIR)/jxl-tool"

## Install man pages
install-man: man
	@echo "Installing man pages to $(MANDIR)..."
	@mkdir -p $(MANDIR)
	@install -m 644 Documentation/man/*.1 $(MANDIR)/
	@if command -v mandb >/dev/null 2>&1; then \
		echo "Updating man page database..."; \
		mandb -q 2>/dev/null || true; \
	fi
	@echo "Man pages installed to $(MANDIR)"

## Uninstall jxl-tool binary
uninstall:
	@echo "Uninstalling jxl-tool from $(BINDIR)..."
	@rm -f $(BINDIR)/jxl-tool
	@echo "Uninstalling man pages from $(MANDIR)..."
	@rm -f $(MANDIR)/jxl-tool*.1
	@if command -v mandb >/dev/null 2>&1; then \
		mandb -q 2>/dev/null || true; \
	fi
	@echo "Uninstalled."

## Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf .build

## Show help
help:
	@echo "JXLSwift Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make build       - Build the project in release mode"
	@echo "  make test        - Run all tests"
	@echo "  make man         - Generate man pages"
	@echo "  make install     - Install jxl-tool binary (requires sudo)"
	@echo "  make install-man - Install man pages (requires sudo)"
	@echo "  make uninstall   - Uninstall jxl-tool and man pages (requires sudo)"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make help        - Show this help message"
	@echo ""
	@echo "Options:"
	@echo "  PREFIX=/path     - Installation prefix (default: /usr/local)"
	@echo ""
	@echo "Examples:"
	@echo "  sudo make install"
	@echo "  sudo make install-man"
	@echo "  make PREFIX=~/.local install"
