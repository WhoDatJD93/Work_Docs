#!/bin/bash
set -euo pipefail

trap 'echo "Error occurred at line $LINENO: Command failed."; exit 1' ERR

echo "Creating directory..."
mkdir /tmp/mydir

echo "Creating file..."
touch /tmp/mydir/testfile

echo "Trying a bad command..."
cp /nonexistent/file /tmp/mydir   # <-- this will fail

echo "This will not run if the above fails"

