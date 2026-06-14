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

import ContainerNetworkClient
import ContainerResource
import Foundation
import Logging
import SystemPackage

/// Represents a single configuration change event
public struct ConfigurationChangeEvent: Codable {
    enum ChangeType: String, Codable {
        case created
        case updated
        case validated
        case syncInitiated
        case syncCompleted
        case syncFailed
        case conflictDetected
        case warningIssued
    }
    
    /// Timestamp of the event
    public let timestamp: Date
    
    /// Type of change that occurred
    public let type: ChangeType
    
    /// Network ID being modified
    public let networkId: String
    
    /// Before state (if applicable)
    public let previousState: NetworkConfiguration?
    
    /// After state (if applicable)
    public let newState: NetworkConfiguration?
    
    /// User-facing message
    public let message: String
    
    /// Additional diagnostic metadata
    public let metadata: [String: String]
    
    public init(
        timestamp: Date = Date(),
        type: ChangeType,
        networkId: String,
        previousState: NetworkConfiguration? = nil,
        newState: NetworkConfiguration? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.type = type
        self.networkId = networkId
        self.previousState = previousState
        self.newState = newState
        self.message = message
        self.metadata = metadata
    }
}

/// Tracks all network configuration changes for audit purposes
public actor ConfigurationAuditLog {
    private var events: [ConfigurationChangeEvent] = []
    private let log: Logger
    private let maxEvents: Int
    
    public init(log: Logger, maxEvents: Int = 1000) {
        self.log = log
        self.maxEvents = maxEvents
    }
    
    /// Record a configuration change event
    public func recordEvent(_ event: ConfigurationChangeEvent) {
        events.append(event)
        
        // Keep only recent events
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        
        log.debug(
            "Configuration audit event recorded",
            metadata: [
                "type": "\(event.type.rawValue)",
                "networkId": "\(event.networkId)",
                "timestamp": "\(event.timestamp.ISO8601Format())",
            ]
        )
    }
    
    /// Get all events for a specific network
    public func eventsForNetwork(_ networkId: String) -> [ConfigurationChangeEvent] {
        events.filter { $0.networkId == networkId }
    }
    
    /// Get recent events (last N)
    public func recentEvents(count: Int = 50) -> [ConfigurationChangeEvent] {
        Array(events.suffix(count))
    }
    
    /// Get all events
    public func allEvents() -> [ConfigurationChangeEvent] {
        events
    }
    
    /// Clear all events
    public func clearEvents() {
        events.removeAll()
        log.info("Configuration audit log cleared")
    }
    
    /// Export events to JSON for diagnostics
    public func exportAsJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(events)
        return String(data: jsonData, encoding: .utf8) ?? ""
    }
}

/// Validates network configurations and detects conflicts
public struct NetworkConfigurationValidator {
    private let log: Logger
    
    public init(log: Logger) {
        self.log = log
    }
    
    /// Check if a subnet overlaps with existing networks
    public func validateSubnetOverlap(
        newConfig: NetworkConfiguration,
        existingNetworks: [NetworkConfiguration]
    ) throws -> (isValid: Bool, conflicts: [String]) {
        var conflicts: [String] = []
        
        guard let newIPv4 = newConfig.ipv4Subnet else {
            return (isValid: true, conflicts: [])
        }
        
        for existing in existingNetworks {
            guard let existingIPv4 = existing.ipv4Subnet else {
                continue
            }
            
            // Check for IPv4 overlap
            if newIPv4.contains(existingIPv4.lower) ||
               newIPv4.contains(existingIPv4.upper) ||
               existingIPv4.contains(newIPv4.lower) ||
               existingIPv4.contains(newIPv4.upper) {
                let conflict = "IPv4 subnet \(newIPv4) overlaps with existing network '\(existing.id)' subnet \(existingIPv4)"
                conflicts.append(conflict)
                log.warning(
                    "Subnet overlap detected",
                    metadata: [
                        "newNetwork": "\(newConfig.id)",
                        "newSubnet": "\(newIPv4)",
                        "existingNetwork": "\(existing.id)",
                        "existingSubnet": "\(existingIPv4)",
                    ]
                )
            }
        }
        
        // Check IPv6 overlap
        if let newIPv6 = newConfig.ipv6Subnet {
            for existing in existingNetworks {
                guard let existingIPv6 = existing.ipv6Subnet else {
                    continue
                }
                
                if newIPv6.contains(existingIPv6.lower) ||
                   newIPv6.contains(existingIPv6.upper) ||
                   existingIPv6.contains(newIPv6.lower) ||
                   existingIPv6.contains(newIPv6.upper) {
                    let conflict = "IPv6 subnet \(newIPv6) overlaps with existing network '\(existing.id)' subnet \(existingIPv6)"
                    conflicts.append(conflict)
                    log.warning(
                        "IPv6 subnet overlap detected",
                        metadata: [
                            "newNetwork": "\(newConfig.id)",
                            "newSubnet": "\(newIPv6)",
                            "existingNetwork": "\(existing.id)",
                            "existingSubnet": "\(existingIPv6)",
                        ]
                    )
                }
            }
        }
        
        return (isValid: conflicts.isEmpty, conflicts: conflicts)
    }
    
    /// Validate that required fields are present and valid
    public func validateConfiguration(_ config: NetworkConfiguration) throws -> (isValid: Bool, issues: [String]) {
        var issues: [String] = []
        
        // Check name
        if config.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("Network name cannot be empty")
        }
        
        // Check plugin
        if config.plugin.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("Network plugin cannot be empty")
        }
        
        // Check mode is valid
        let validModes = ["nat", "hostOnly"]
        if !validModes.contains(config.mode.rawValue) {
            issues.append("Invalid network mode: \(config.mode.rawValue)")
        }
        
        if !issues.isEmpty {
            log.error(
                "Configuration validation failed",
                metadata: [
                    "networkId": "\(config.id)",
                    "issueCount": "\(issues.count)",
                ]
            )
        }
        
        return (isValid: issues.isEmpty, issues: issues)
    }
    
    /// Detect changes between two configurations
    public func detectChanges(
        from: NetworkConfiguration,
        to: NetworkConfiguration
    ) -> [String] {
        var changes: [String] = []
        
        if from.name != to.name {
            changes.append("Name: '\(from.name)' → '\(to.name)'")
        }
        
        if from.mode != to.mode {
            changes.append("Mode: \(from.mode.rawValue) → \(to.mode.rawValue)")
        }
        
        if from.ipv4Subnet?.description != to.ipv4Subnet?.description {
            let fromStr = from.ipv4Subnet?.description ?? "none"
            let toStr = to.ipv4Subnet?.description ?? "none"
            changes.append("IPv4 Subnet: \(fromStr) → \(toStr)")
        }
        
        if from.ipv6Subnet?.description != to.ipv6Subnet?.description {
            let fromStr = from.ipv6Subnet?.description ?? "none"
            let toStr = to.ipv6Subnet?.description ?? "none"
            changes.append("IPv6 Subnet: \(fromStr) → \(toStr)")
        }
        
        if from.plugin != to.plugin {
            changes.append("Plugin: '\(from.plugin)' → '\(to.plugin)'")
        }
        
        return changes
    }
}

/// Enhanced network configuration change tracker
public struct ConfigurationChangeTracker {
    private let auditLog: ConfigurationAuditLog
    private let validator: NetworkConfigurationValidator
    private let log: Logger
    
    public init(
        auditLog: ConfigurationAuditLog,
        validator: NetworkConfigurationValidator,
        log: Logger
    ) {
        self.auditLog = auditLog
        self.validator = validator
        self.log = log
    }
    
    /// Track a configuration update with full validation and auditing
    public func trackUpdate(
        networkId: String,
        oldConfig: NetworkConfiguration?,
        newConfig: NetworkConfiguration,
        existingNetworks: [NetworkConfiguration],
        reason: String
    ) async throws {
        // Validate new configuration
        let (isValid, issues) = validator.validateConfiguration(newConfig)
        if !isValid {
            log.error(
                "Configuration validation failed before update",
                metadata: [
                    "networkId": networkId,
                    "issues": issues.joined(separator: "; "),
                ]
            )
            throw ContainerizationError(.invalidArgument, message: "Invalid configuration: \(issues.joined(separator: ", "))")
        }
        
        // Check for overlaps (exclude the network being updated)
        let otherNetworks = existingNetworks.filter { $0.id != networkId }
        let (noOverlap, conflicts) = try validator.validateSubnetOverlap(
            newConfig: newConfig,
            existingNetworks: otherNetworks
        )
        
        if !noOverlap {
            let conflictMsg = conflicts.joined(separator: "; ")
            log.error(
                "Configuration update blocked due to subnet conflicts",
                metadata: [
                    "networkId": networkId,
                    "conflicts": conflictMsg,
                ]
            )
            
            // Record the blocked update
            await auditLog.recordEvent(ConfigurationChangeEvent(
                type: .conflictDetected,
                networkId: networkId,
                previousState: oldConfig,
                newState: newConfig,
                message: "Update blocked: \(conflictMsg)",
                metadata: ["reason": reason]
            ))
            
            throw ContainerizationError(.invalidArgument, message: conflictMsg)
        }
        
        // Detect and log changes
        var changeDetails = [String]()
        if let oldConfig = oldConfig {
            changeDetails = validator.detectChanges(from: oldConfig, to: newConfig)
        } else {
            changeDetails = ["New network created"]
        }
        
        let changeMsg = changeDetails.joined(separator: "; ")
        log.info(
            "Configuration update",
            metadata: [
                "networkId": networkId,
                "changes": changeMsg,
                "reason": reason,
            ]
        )
        
        // Record the update
        await auditLog.recordEvent(ConfigurationChangeEvent(
            type: .updated,
            networkId: networkId,
            previousState: oldConfig,
            newState: newConfig,
            message: "Configuration updated: \(changeMsg)",
            metadata: [
                "reason": reason,
                "changeCount": "\(changeDetails.count)",
            ]
        ))
    }
    
    /// Track a sync operation
    public func trackSyncStart(
        networkId: String,
        reason: String
    ) async {
        log.info(
            "Network configuration sync initiated",
            metadata: [
                "networkId": networkId,
                "reason": reason,
            ]
        )
        
        await auditLog.recordEvent(ConfigurationChangeEvent(
            type: .syncInitiated,
            networkId: networkId,
            message: "Configuration sync started: \(reason)",
            metadata: ["reason": reason]
        ))
    }
    
    /// Track successful sync completion
    public func trackSyncSuccess(
        networkId: String,
        oldConfig: NetworkConfiguration?,
        newConfig: NetworkConfiguration
    ) async {
        let changes = oldConfig.map { validator.detectChanges(from: $0, to: newConfig) } ?? []
        let changeMsg = changes.isEmpty ? "No changes" : changes.joined(separator: "; ")
        
        log.info(
            "Network configuration sync completed successfully",
            metadata: [
                "networkId": networkId,
                "changes": changeMsg,
            ]
        )
        
        await auditLog.recordEvent(ConfigurationChangeEvent(
            type: .syncCompleted,
            networkId: networkId,
            previousState: oldConfig,
            newState: newConfig,
            message: "Configuration sync completed: \(changeMsg)"
        ))
    }
    
    /// Track sync failure
    public func trackSyncFailure(
        networkId: String,
        error: Error,
        attemptedConfig: NetworkConfiguration?
    ) async {
        log.error(
            "Network configuration sync failed",
            metadata: [
                "networkId": networkId,
                "error": "\(error)",
            ]
        )
        
        await auditLog.recordEvent(ConfigurationChangeEvent(
            type: .syncFailed,
            networkId: networkId,
            newState: attemptedConfig,
            message: "Configuration sync failed: \(error.localizedDescription)"
        ))
    }
    
    /// Get audit trail for a network
    public func getAuditTrail(networkId: String) async -> [ConfigurationChangeEvent] {
        await auditLog.eventsForNetwork(networkId)
    }
}
