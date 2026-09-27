# Third-party components

The DMG bundles `pymobiledevice3` 11.19.1 (GPL-3.0-or-later) and its runtime dependencies. Its license is included as `LICENSE-pymobiledevice3.txt` inside the app. MochiLog Mac's source and packaging recipe are available in this repository. Dependency source: https://github.com/doronz88/pymobiledevice3

The bundled Sparkle update framework is licensed under the MIT License. Its license is included as `LICENSE-Sparkle.txt` inside the app. Project source: https://github.com/sparkle-project/Sparkle

License texts and package metadata for the Python environment used to build the collector are included as `LICENSE-Python-Dependencies.txt` and individually under `PythonLicenses/` inside the app. The in-app viewer lists each package separately. This report includes build-time packages as well as runtime packages so that the complete bundled environment is documented. Some upstream packages declare a license but do not ship a license text in their distribution; their declaration and project URL are shown without inventing a notice.

`pymobiledevice3` talks to iOS device services through macOS's `remoted` facility. End users do not need to install Python, Xcode, Homebrew, or a separate command-line helper.
