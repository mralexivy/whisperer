#!/bin/bash

# Whisperer Setup Verification Script
# Run this to check if all files are in place before creating Xcode project

echo "🔍 Verifying Whisperer project files..."
echo ""

# Change to the Whisperer subdirectory where source files are
cd "$(dirname "$0")/Whisperer" || exit 1

errors=0
warnings=0

# Check core files
check_file() {
    if [ -f "$1" ]; then
        echo "✅ $1"
    else
        echo "❌ MISSING: $1"
        ((errors++))
    fi
}

check_dir() {
    if [ -d "$1" ]; then
        echo "✅ $1/"
    else
        echo "❌ MISSING: $1/"
        ((errors++))
    fi
}

# Core files
echo "Core Files:"
check_file "WhispererApp.swift"
check_file "AppState.swift"
check_file "Info.plist"
echo ""

# UI files
echo "UI Components:"
check_dir "UI"
check_file "UI/OverlayPanel.swift"
check_file "UI/OverlayView.swift"
check_file "UI/WaveformView.swift"
echo ""

# Audio files
echo "Audio Components:"
check_dir "Audio"
check_file "Audio/AudioRecorder.swift"
echo ""

# KeyListener files
echo "Key Listener:"
check_dir "KeyListener"
check_file "KeyListener/GlobalKeyListener.swift"
echo ""

# Transcription files
echo "Transcription Engine:"
check_dir "Transcription"
check_file "Transcription/WhisperRunner.swift"
check_file "Transcription/ModelDownloader.swift"
echo ""

# TextInjection files
echo "Text Injection:"
check_dir "TextInjection"
check_file "TextInjection/TextInjector.swift"
echo ""

# Resources
echo "Resources:"
check_dir "Resources"
check_file "Resources/whisper-cli"
echo ""

# Check whisper-cli is executable
if [ -f "Resources/whisper-cli" ]; then
    if [ -x "Resources/whisper-cli" ]; then
        echo "✅ whisper-cli is executable"
    else
        echo "⚠️  whisper-cli is not executable (will be fixed on first run)"
        ((warnings++))
    fi

    # Check file size (should be > 100KB)
    size=$(stat -f%z "Resources/whisper-cli" 2>/dev/null || stat -c%s "Resources/whisper-cli" 2>/dev/null)
    if [ "$size" -gt 100000 ]; then
        echo "✅ whisper-cli size: $(numfmt --to=iec $size 2>/dev/null || echo ${size} bytes)"
    else
        echo "⚠️  whisper-cli seems too small (expected ~800KB)"
        ((warnings++))
    fi
fi
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    echo "✅ All checks passed!"
    echo ""
    echo "Next steps:"
    echo "1. Read SETUP.md for Xcode project creation"
    echo "2. Create new Xcode project following the guide"
    echo "3. Build and run!"
elif [ $errors -eq 0 ]; then
    echo "✅ All required files present"
    echo "⚠️  $warnings warning(s) - check above"
    echo ""
    echo "You can proceed with setup, but review warnings."
else
    echo "❌ $errors error(s) found"
    echo "⚠️  $warnings warning(s)"
    echo ""
    echo "Fix missing files before proceeding."
    exit 1
fi

# Check if .xcodeproj exists
if [ -d "Whisperer.xcodeproj" ]; then
    echo ""
    echo "ℹ️  Xcode project already exists at Whisperer.xcodeproj"
    echo "   You can open it with: open Whisperer.xcodeproj"
fi

exit 0
