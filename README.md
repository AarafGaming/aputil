# aputil

APUtil stands for Application Package Utility and is an offline-first user-space package manager with both self-contained and dependency required packages.
Dependency required prevents duplication while self-contained prevents dependency hell (best of both worlds).

# Usage
aputil install < package-path > - Installs a package
aputil info < package-path > - Outputs what installing a package runs
aputil upgrade < package-path > - Upgrades a package
aputil list-packages - Lists packages

# Extra
You cannot spam yes. You have to approve each command the package runs.