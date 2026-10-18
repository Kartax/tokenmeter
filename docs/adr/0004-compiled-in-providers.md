# Providers are compiled in; no runtime plugins

Each Provider is a Swift module folder behind one shared interface, registered at compile time; adding a Provider means a code change and a release. Runtime plugins (scripts or declarative HTTP configs) were rejected because every Provider authenticates differently (borrowed Keychain tokens, device-code OAuth, API keys), so a plugin format would be either too weak or a scripting engine, and staying small and focused is TokenMeter's point of difference from CodexBar.
