//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerCommands
import Foundation
import container_apiserver
import container_core_images
import container_network_vmnet
import container_runtime_linux

// Equivalent to `AsyncParsableCommand.main(_:)`, inlined here because Swift's
// overload resolution on `Type.main(_:)` prefers the synchronous
// `ParsableCommand.main(_:)` even when the metatype is `any
// AsyncParsableCommand.Type`, which short-circuits async `run()`s to a
// help-request throw.
func runHelperAsync(_ type: any AsyncParsableCommand.Type, _ arguments: [String]) async -> Never {
    do {
        var command = try type.parseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
        type.exit()
    } catch {
        type.exit(withError: error)
    }
}

let argv = CommandLine.arguments
let invokedAs = (argv.first as NSString?)?.lastPathComponent ?? "container"
let forwarded = Array(argv.dropFirst())

switch invokedAs {
case "container-apiserver":
    await runHelperAsync(APIServer.self, forwarded)
case "container-core-images":
    await runHelperAsync(ImagesHelper.self, forwarded)
case "container-network-vmnet":
    await runHelperAsync(NetworkVmnetHelper.self, forwarded)
case "container-runtime-linux":
    await runHelperAsync(RuntimeLinuxHelper.self, forwarded)
default:
    try await runContainerCLI()
}
