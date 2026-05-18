//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

/// Resolves the launchd / Mach service namespace shared by all `container` services.
///
/// Setting the `CONTAINER_LAUNCH_PREFIX` environment variable lets multiple,
/// fully independent `container` systems coexist on one machine: each gets a
/// distinct set of launchd labels and Mach service names, so their daemons,
/// plugins, and per-container helpers never collide. Pair it with
/// `CONTAINER_APP_ROOT` to also isolate on-disk state.
public enum ServiceNamespace {
    /// Environment variable that overrides the service namespace prefix.
    public static let environmentName = "CONTAINER_LAUNCH_PREFIX"

    /// Prefix used when `CONTAINER_LAUNCH_PREFIX` is unset or empty.
    public static let defaultPrefix = "com.apple.container"

    /// Resolves the prefix from an explicit environment. Exposed for testing.
    public static func resolvePrefix(env: [String: String]) -> String {
        guard let value = env[environmentName], !value.isEmpty else {
            return defaultPrefix
        }
        return value
    }

    /// The reverse-DNS prefix shared by every launchd label and Mach service.
    public static let prefix = resolvePrefix(env: ProcessInfo.processInfo.environment)

    /// The prefix with a trailing dot, e.g. `com.apple.container.`.
    public static var dottedPrefix: String { "\(prefix)." }

    /// The launchd label and Mach service name of the API server.
    public static var apiServer: String { "\(prefix).apiserver" }

    /// The Mach service name of the core images plugin.
    public static var coreImages: String { "\(prefix).core.container-core-images" }

    /// The Mach service name prefix for container runtime plugins. Per-container
    /// services append the runtime name and container id.
    public static var runtime: String { "\(prefix).runtime" }

    /// The Mach service name prefix for network plugins. Per-network services
    /// append the plugin name and network id.
    public static var network: String { "\(prefix).network" }
}
