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

import ContainerAPIClient
import ContainerNetworkClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

/// Diagnostic utilities for network configuration
public struct NetworkConfigurationDiagnostics {
    private let log: Logger
    
    public init(log: Logger) {
        self.log = log
    }
    
    /// Generate a comprehensive diagnostic report
    public func generateReport(
        networks: [NetworkConfiguration],
        auditEvents: [ConfigurationChangeEvent]
    ) -> String {
        var report = """
        ═══════════════════════════════════════════════════════
        NETWORK CONFIGURATION DIAGNOSTIC REPORT
        ═══════════════════════════════════════════════════════
        
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        
        """
        
        // Network Summary
        report += """
        NETWORKS SUMMARY
        ───────────────────────────────────────────────────────
        Total Networks: \(networks.count)
        
        """
        
        for network in networks.sorted(by: { $0.id < $1.id }) {
            report += """
            Network: \(network.id)
              Name: \(network.name)
              Mode: \(network.mode.rawValue)
              Plugin: \(network.plugin)
              IPv4: \(network.ipv4Subnet?.description ?? "not configured")
              IPv6: \(network.ipv6Subnet?.description ?? "not configured")
              Builtin: \(network.labels.isBuiltin)
            
            """
        }
        
        // Subnet Conflict Analysis
        report += """
        SUBNET ANALYSIS
        ───────────────────────────────────────────────────────
        """
        
        let ipv4Subnets = networks.compactMap { ($0.id, $0.ipv4Subnet) }
        var foundConflicts = false
        
        for (id1, subnet1) in ipv4Subnets {
            for (id2, subnet2) in ipv4Subnets where id1 < id2 {
                if subnet1.contains(subnet2.lower) ||
                   subnet1.contains(subnet2.upper) ||
                   subnet2.contains(subnet1.lower) ||
                   subnet2.contains(subnet1.upper) {
                    foundConflicts = true
                    report += """
                    ⚠️  IPv4 OVERLAP DETECTED:
                        Network: \(id1) - \(subnet1)
                        Network: \(id2) - \(subnet2)
                    
                    """
                }
            }
        }
        
        if !foundConflicts {
            report += "✓ No IPv4 subnet conflicts detected\n\n"
        }
        
        // IPv6 Conflict Analysis
        let ipv6Subnets = networks.compactMap { ($0.id, $0.ipv6Subnet) }
        foundConflicts = false
        
        for (id1, subnet1) in ipv6Subnets {
            for (id2, subnet2) in ipv6Subnets where id1 < id2 {
                if subnet1.contains(subnet2.lower) ||
                   subnet1.contains(subnet2.upper) ||
                   subnet2.contains(subnet1.lower) ||
                   subnet2.contains(subnet1.upper) {
                    foundConflicts = true
                    report += """
                    ⚠️  IPv6 OVERLAP DETECTED:
                        Network: \(id1) - \(subnet1)
                        Network: \(id2) - \(subnet2)
                    
                    """
                }
            }
        }
        
        if !foundConflicts {
            report += "✓ No IPv6 subnet conflicts detected\n\n"
        }
        
        // Audit Trail
        report += """
        RECENT AUDIT EVENTS (Last 30)
        ───────────────────────────────────────────────────────
        """
        
        if auditEvents.isEmpty {
            report += "No audit events recorded\n\n"
        } else {
            for event in auditEvents.suffix(30).reversed() {
                let timeStr = ISO8601DateFormatter().string(from: event.timestamp)
                let icon = iconForEventType(event.type)
                report += """
                \(icon) [\(timeStr)] \(event.type.rawValue.uppercased())
                  Network: \(event.networkId)
                  Message: \(event.message)
                """
                
                if !event.metadata.isEmpty {
                    report += "\n  Metadata:"
                    for (key, value) in event.metadata.sorted(by: { $0.key < $1.key }) {
                        report += "\n    \(key): \(value)"
                    }
                }
                
                report += "\n\n"
            }
        }
        
        report += "═══════════════════════════════════════════════════════\n"
        
        return report
    }
    
    /// Check and report on configuration sync status
    public func analyzeSyncStatus(
        expectedConfig: NetworkConfiguration,
        actualNetworks: [NetworkConfiguration]
    ) -> (isSynced: Bool, issues: [String]) {
        var issues: [String] = []
        
        guard let actualNetwork = actualNetworks.first(where: { $0.id == expectedConfig.id }) else {
            issues.append("Network '\(expectedConfig.id)' not found in active networks")
            return (isSynced: false, issues: issues)
        }
        
        if expectedConfig.ipv4Subnet?.description != actualNetwork.ipv4Subnet?.description {
            issues.append(
                "IPv4 Subnet mismatch for '\(expectedConfig.id)': "
                + "expected \(expectedConfig.ipv4Subnet?.description ?? "none"), "
                + "got \(actualNetwork.ipv4Subnet?.description ?? "none")"
            )
        }
        
        if expectedConfig.ipv6Subnet?.description != actualNetwork.ipv6Subnet?.description {
            issues.append(
                "IPv6 Subnet mismatch for '\(expectedConfig.id)': "
                + "expected \(expectedConfig.ipv6Subnet?.description ?? "none"), "
                + "got \(actualNetwork.ipv6Subnet?.description ?? "none")"
            )
        }
        
        if expectedConfig.plugin != actualNetwork.plugin {
            issues.append(
                "Plugin mismatch for '\(expectedConfig.id)': "
                + "expected \(expectedConfig.plugin), got \(actualNetwork.plugin)"
            )
        }
        
        if expectedConfig.mode != actualNetwork.mode {
            issues.append(
                "Mode mismatch for '\(expectedConfig.id)': "
                + "expected \(expectedConfig.mode.rawValue), got \(actualNetwork.mode.rawValue)"
            )
        }
        
        return (isSynced: issues.isEmpty, issues: issues)
    }
    
    /// Generate a summary of network health
    public func generateHealthSummary(
        networks: [NetworkConfiguration],
        recentEvents: [ConfigurationChangeEvent]
    ) -> String {
        var summary = "NETWORK HEALTH SUMMARY\n"
        summary += "────────────────────────────────────────────────────\n"
        summary += "Total Networks: \(networks.count)\n"
        
        let builtinCount = networks.filter { $0.labels.isBuiltin }.count
        summary += "Builtin Networks: \(builtinCount)\n"
        summary += "Custom Networks: \(networks.count - builtinCount)\n"
        
        let recentErrors = recentEvents.filter { 
            $0.type == .syncFailed || $0.type == .conflictDetected 
        }
        
        if recentErrors.isEmpty {
            summary += "Recent Errors: None ✓\n"
        } else {
            summary += "Recent Errors: \(recentErrors.count) ⚠️\n"
            for error in recentErrors.suffix(5) {
                summary += "  • \(error.networkId): \(error.message)\n"
            }
        }
        
        return summary
    }
    
    private func iconForEventType(_ type: ConfigurationChangeEvent.ChangeType) -> String {
        switch type {
        case .created:
            return "✨"
        case .updated:
            return "🔄"
        case .validated:
            return "✓"
        case .syncInitiated:
            return "▶️"
        case .syncCompleted:
            return "✅"
        case .syncFailed:
            return "❌"
        case .conflictDetected:
            return "⚠️"
        case .warningIssued:
            return "⚠️"
        }
    }
}

/// Enhanced extension to provide comprehensive logging during network initialization
extension NetworksService {
    /// Initialize with full audit and validation logging support
    public static func initializeWithAuditLogging(
        pluginLoader: PluginLoader,
        resourceRoot: FilePath,
        containersService: ContainersService,
        defaultNetworkConfiguration: NetworkConfiguration,
        log: Logger,
        debugHelpers: Bool = false,
        auditLog: ConfigurationAuditLog
    ) async throws -> (service: NetworksService, changeTracker: ConfigurationChangeTracker) {
        let validator = NetworkConfigurationValidator(log: log)
        let changeTracker = ConfigurationChangeTracker(
            auditLog: auditLog,
            validator: validator,
            log: log
        )
        
        log.info(
            "Initializing Networks service with audit support",
            metadata: [
                "defaultNetwork": "\(defaultNetworkConfiguration.id)",
                "ipv4Subnet": "\(defaultNetworkConfiguration.ipv4Subnet?.description ?? "not configured")",
                "ipv6Subnet": "\(defaultNetworkConfiguration.ipv6Subnet?.description ?? "not configured")",
                "plugin": "\(defaultNetworkConfiguration.plugin)",
            ]
        )
        
        // Track initialization
        await changeTracker.trackSyncStart(
            networkId: defaultNetworkConfiguration.id,
            reason: "System initialization - loading TOML configuration"
        )
        
        let service = try await NetworksService(
            pluginLoader: pluginLoader,
            resourceRoot: resourceRoot,
            containersService: containersService,
            defaultNetworkConfiguration: defaultNetworkConfiguration,
            log: log,
            debugHelpers: debugHelpers
        )
        
        log.info(
            "Networks service initialized successfully",
            metadata: [
                "totalNetworks": "\(await service.list().count)",
            ]
        )
        
        return (service: service, changeTracker: changeTracker)
    }
}

/// Configuration initialization context for passing audit info through initialization
public struct ConfigurationInitializationContext {
    public let auditLog: ConfigurationAuditLog
    public let changeTracker: ConfigurationChangeTracker
    public let validator: NetworkConfigurationValidator
    public let diagnostics: NetworkConfigurationDiagnostics
    public let log: Logger
    
    public init(log: Logger) {
        self.log = log
        self.auditLog = ConfigurationAuditLog(log: log)
        self.validator = NetworkConfigurationValidator(log: log)
        self.changeTracker = ConfigurationChangeTracker(
            auditLog: auditLog,
            validator: validator,
            log: log
        )
        self.diagnostics = NetworkConfigurationDiagnostics(log: log)
    }
}

/// Extension to track and validate network configuration during sync operations
extension ConfigurationChangeTracker {
    /// Track a complete sync operation with before/after validation
    public func trackFullSync(
        networkId: String,
        oldConfig: NetworkConfiguration?,
        newConfig: NetworkConfiguration,
        existingNetworks: [NetworkConfiguration],
        validator: NetworkConfigurationValidator
    ) async throws {
        // Validate configuration
        let (isValid, issues) = validator.validateConfiguration(newConfig)
        if !isValid {
            await trackSyncFailure(
                networkId: networkId,
                error: ContainerizationError(.invalidArgument, message: issues.joined(separator: ", ")),
                attemptedConfig: newConfig
            )
            throw ContainerizationError(.invalidArgument, message: "Configuration validation failed")
        }
        
        // Check for overlaps
        let otherNetworks = existingNetworks.filter { $0.id != networkId }
        let (noOverlap, conflicts) = try validator.validateSubnetOverlap(
            newConfig: newConfig,
            existingNetworks: otherNetworks
        )
        
        if !noOverlap {
            let conflictMsg = conflicts.joined(separator: "; ")
            await trackSyncFailure(
                networkId: networkId,
                error: ContainerizationError(.invalidArgument, message: conflictMsg),
                attemptedConfig: newConfig
            )
            throw ContainerizationError(.invalidArgument, message: conflictMsg)
        }
        
        // Track the update
        try await trackUpdate(
            networkId: networkId,
            oldConfig: oldConfig,
            newConfig: newConfig,
            existingNetworks: existingNetworks,
            reason: "Configuration sync during initialization"
        )
        
        // Mark sync as successful
        await trackSyncSuccess(
            networkId: networkId,
            oldConfig: oldConfig,
            newConfig: newConfig
        )
    }
    
    /// Export audit log as JSON for external analysis
    public func exportAuditLog() async throws -> String {
        try await auditLog.exportAsJSON()
    }
}
