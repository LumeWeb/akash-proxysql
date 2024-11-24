#!/bin/bash

# Declare first
declare -gx LIB_PATH

# Then assign with error checking
if ! LIB_PATH=$(realpath "${LIB_PATH:-"/usr/local/lib"}"); then
    echo "Error: Failed to resolve library path" >&2
    exit 1
fi

# Verify directory exists and is readable
if [ ! -d "$LIB_PATH" ]; then
    echo "Error: $LIB_PATH is not a directory" >&2
    exit 1
fi

if [ ! -r "$LIB_PATH" ]; then
    echo "Error: $LIB_PATH is not readable" >&2
    exit 1
fi
