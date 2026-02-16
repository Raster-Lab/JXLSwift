# jxl-tool Manual Pages

This directory contains the manual pages for `jxl-tool`, the command-line tool for JXLSwift.

## Generation

The man pages are automatically generated from the ArgumentParser command definitions using the `generate-manual` plugin:

```bash
swift package --allow-writing-to-directory Documentation/man generate-manual --multi-page --output-directory Documentation/man
```

## Installation

### macOS / Linux

To install the man pages system-wide, run:

```bash
sudo make install-man
```

Or manually copy the man pages to your system's man directory:

```bash
sudo mkdir -p /usr/local/share/man/man1
sudo cp Documentation/man/*.1 /usr/local/share/man/man1/
sudo mandb  # Update man page database (Linux)
```

### Usage

Once installed, you can access the man pages with:

```bash
man jxl-tool
man jxl-tool-encode
man jxl-tool-benchmark
# etc.
```

## Available Man Pages

- `jxl-tool.1` - Main tool overview
- `jxl-tool.encode.1` - Encode subcommand
- `jxl-tool.info.1` - Info subcommand
- `jxl-tool.hardware.1` - Hardware subcommand
- `jxl-tool.benchmark.1` - Benchmark subcommand
- `jxl-tool.batch.1` - Batch subcommand
- `jxl-tool.compare.1` - Compare subcommand
- `jxl-tool.help.1` - Help subcommand

## Viewing Without Installation

You can view the man pages without installation using:

```bash
man ./Documentation/man/jxl-tool.1
```
