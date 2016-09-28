#!/bin/bash
# This is a helper script which is called by docker-storage-setup.sh (d-s-s).
# This script helps in providing synchronization primitives to d-s-s so that
# d-s-s can determine whether deferred deletion is supported by the underlying
# kernel or not.

# $1 is named FIFO pipe.
# This helper script will write to $1 to signal d-s-s that unshare has been completed successfully.
echo "start" > $1
# $2 is another named FIFO pipe.
# This helper script will read from $2. The write for this pipe would come from d-s-s to indicate
# that helper script can terminate now.
read -t 10 n <>$2
