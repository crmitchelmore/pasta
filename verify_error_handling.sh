#!/bin/bash

# Error Handling Verification Script
# Run this to verify the error handling implementation

set -e

echo "=== Pasta Error Handling Verification ==="
echo

echo "1. Building project..."
if swift build; then
    echo "✅ Build successful"
else
    echo "❌ Build failed"
    exit 1
fi

echo
echo "2. Checking for PastaError.swift..."
if [ -f "Sources/PastaCore/PastaError.swift" ]; then
    echo "✅ PastaError.swift exists"
    grep -q "enum PastaError" Sources/PastaCore/PastaError.swift && echo "   - PastaError enum defined"
    grep -q "struct PastaLogger" Sources/PastaCore/PastaError.swift && echo "   - PastaLogger defined"
else
    echo "❌ PastaError.swift not found"
fi

echo
echo "3. Checking os.log imports..."
for file in Sources/PastaCore/DatabaseManager.swift \
            Sources/PastaCore/ImageStorageManager.swift \
            Sources/PastaCore/ClipboardMonitor.swift \
            Sources/PastaCore/HotkeyManager.swift \
            Sources/PastaCore/PasteService.swift \
            Sources/PastaCore/DeleteService.swift \
            Sources/PastaApp/AppViewModel.swift; do
    if grep -q "import os.log" "$file" 2>/dev/null; then
        echo "✅ $(basename $file) has os.log import"
    else
        echo "⚠️  $(basename $file) missing os.log import"
    fi
done

echo
echo "4. Checking error handling in DatabaseManager..."
grep -q "PastaError.databaseCorrupted" Sources/PastaCore/DatabaseManager.swift && echo "✅ Database corruption handling"
grep -q "PastaLogger.database" Sources/PastaCore/DatabaseManager.swift && echo "✅ Database logging"

echo
echo "5. Checking error handling in ImageStorageManager..."
grep -q "PastaError.diskFull" Sources/PastaCore/ImageStorageManager.swift && echo "✅ Disk full handling"
grep -q "NSFileWriteOutOfSpaceError" Sources/PastaCore/ImageStorageManager.swift && echo "✅ Disk space error detection"
grep -q "PastaLogger.storage" Sources/PastaCore/ImageStorageManager.swift && echo "✅ Storage logging"

echo
echo "6. Checking UI error display in PastaApp.swift..."
grep -q "lastError: PastaError?" Sources/PastaApp/AppViewModel.swift && echo "✅ AppViewModel publishes errors"
grep -q "isShowingErrorAlert" Sources/PastaApp/PastaApp.swift && echo "✅ PopoverRootView has error alert state"
grep -q "\.alert(" Sources/PastaApp/PastaApp.swift && echo "✅ Alert modifier added"

echo
echo "7. Checking clipboard monitoring logging..."
grep -q "PastaLogger.clipboard" Sources/PastaCore/ClipboardMonitor.swift && echo "✅ Clipboard logging"

echo
echo "8. Checking graceful degradation in AppViewModel..."
grep -q "DatabaseManager.inMemory()" Sources/PastaApp/AppViewModel.swift && echo "✅ In-memory database fallback"
grep -q "\.temporaryDirectory" Sources/PastaApp/AppViewModel.swift && echo "✅ Temporary storage fallback"

echo
echo "=== Verification Complete ==="
echo
echo "To monitor logs while running the app:"
echo "  log stream --predicate 'subsystem == \"com.pasta.clipboard\"' --level debug"
echo
echo "To test error scenarios:"
echo "  1. Database corruption: echo 'corrupt' > ~/Library/Application\\ Support/Pasta/pasta.sqlite"
echo "  2. Check logs: log show --predicate 'subsystem == \"com.pasta.clipboard\"' --last 5m"
