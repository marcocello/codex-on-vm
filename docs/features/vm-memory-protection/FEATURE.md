# VM memory protection

The operator needs a recoverable memory reserve and local measurements when the VM runs concurrent workloads.

- VM preparation creates and activates a 2 GiB OS-disk swap file and makes it persistent. It preserves an existing swap configuration and stops for inspection instead of replacing it.
- VM preparation installs a timer that records available memory, swap usage, and memory pressure every minute. It records a warning when available memory is below 15%, swap use is at least 75%, or full memory pressure over one minute is at least 10%.
- Existing services and MCP sessions remain running. Samples and warnings remain in the system journal; external notification is not included.
- After OS-disk replacement, the operator reruns VM preparation to restore the protection.
