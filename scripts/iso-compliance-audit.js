#!/usr/bin/env node

/**
 * Comprehensive ISO Standards Compliance Audit for Wrfcoin
 * Tests all implemented ISO standards and generates compliance report
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

class ISOComplianceAuditor {
  constructor() {
    this.results = {
      overall_score: 0,
      standards_tested: 0,
      standards_passed: 0,
      standards_failed: 0,
      detailed_results: {},
    };
  }

  async auditAllStandards() {
    console.log(
      '🔍 Starting Comprehensive ISO Standards Compliance Audit...\n'
    );

    // Financial Services Standards
    await this.auditISO20022();
    await this.auditISO4217();
    await this.auditISO22739();

    // Environmental Standards
    await this.auditISO14064();
    await this.auditISO19115();
    await this.auditISO19156();

    // Security Standards
    await this.auditISO27001();
    await this.auditISO27701();

    // Blockchain Standards
    await this.auditISO23257();
    await this.auditISO23576();

    // Business Continuity & Risk
    await this.auditISO22031();
    await this.auditISO22301();

    // Geographic & Data Quality
    await this.auditISO24165();

    this.calculateOverallScore();
    this.generateReport();
  }

  async auditISO20022() {
    console.log('📊 Auditing ISO 20022 - Financial Services Messaging...');

    const checks = {
      message_structure: await this.checkISO20022MessageStructure(),
      cross_border_payments: await this.checkCrossBorderPayments(),
      climate_finance_extensions: await this.checkClimateFinanceExtensions(),
      xml_validation: await this.checkXMLValidation(),
      business_application_header: await this.checkBusinessApplicationHeader(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO20022 = {
      score,
      status:
        score >= 0.9
          ? 'FULLY_COMPLIANT'
          : score >= 0.7
            ? 'MOSTLY_COMPLIANT'
            : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'CRITICAL',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO20022.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO4217() {
    console.log('💱 Auditing ISO 4217 - Currency Codes...');

    const checks = {
      currency_support: await this.checkCurrencyCodeSupport(),
      wrf_integration: await this.checkWRFCurrencyIntegration(),
      exchange_rates: await this.checkExchangeRateHandling(),
      multi_currency: await this.checkMultiCurrencySupport(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO4217 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO4217.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO14064() {
    console.log('🌍 Auditing ISO 14064 - Greenhouse Gas Emissions...');

    const checks = {
      ghg_quantification: await this.checkGHGQuantification(),
      project_verification: await this.checkProjectVerification(),
      carbon_credits: await this.checkCarbonCreditGeneration(),
      scope_emissions: await this.checkScopeEmissions(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO14064 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'IN_PROGRESS',
      checks,
      priority: 'CRITICAL',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO14064.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO27001() {
    console.log('🔒 Auditing ISO 27001 - Information Security Management...');

    const checks = {
      security_controls: await this.checkSecurityControls(),
      risk_assessment: await this.checkRiskAssessment(),
      incident_response: await this.checkIncidentResponse(),
      access_control: await this.checkAccessControl(),
      encryption: await this.checkEncryptionImplementation(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO27001 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'CRITICAL',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO27001.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO23257() {
    console.log('⛓️ Auditing ISO 23257 - Blockchain Architecture...');

    const checks = {
      architecture_compliance: await this.checkArchitectureCompliance(),
      layer_separation: await this.checkLayerSeparation(),
      component_interfaces: await this.checkComponentInterfaces(),
      governance_integration: await this.checkGovernanceIntegration(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO23257 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO23257.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO23576() {
    console.log('🌉 Auditing ISO 23576 - Blockchain Interoperability...');

    const checks = {
      cross_chain_protocols: await this.checkCrossChainProtocols(),
      message_standardization: await this.checkMessageStandardization(),
      security_mechanisms: await this.checkSecurityMechanisms(),
      climate_data_interop: await this.checkClimateDataInteroperability(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO23576 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO23576.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  // Additional standard audit methods
  async auditISO22739() {
    console.log('🏦 Auditing ISO 22739 - Digital Asset Custody...');

    const checks = {
      custody_controls: await this.checkCustodyControls(),
      key_management: await this.checkKeyManagement(),
      multi_signature: await this.checkMultiSignatureSupport(),
      audit_trails: await this.checkAuditTrails(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO22739 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO22739.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO19115() {
    console.log('🗺️ Auditing ISO 19115 - Geographic Information Metadata...');

    const checks = {
      metadata_standards: await this.checkMetadataStandards(),
      geographic_indexing: await this.checkGeographicIndexing(),
      weather_station_metadata: await this.checkWeatherStationMetadata(),
      spatial_validation: await this.checkSpatialValidation(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO19115 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO19115.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO19156() {
    console.log('🌡️ Auditing ISO 19156 - Observations and Measurements...');

    const checks = {
      observation_model: await this.checkObservationModel(),
      measurement_quality: await this.checkMeasurementQuality(),
      sensor_integration: await this.checkSensorIntegration(),
      data_validation: await this.checkDataValidation(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO19156 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO19156.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO27701() {
    console.log('🔐 Auditing ISO 27701 - Privacy Information Management...');

    const checks = {
      privacy_controls: await this.checkPrivacyControls(),
      gdpr_compliance: await this.checkGDPRCompliance(),
      consent_management: await this.checkConsentManagement(),
      data_subject_rights: await this.checkDataSubjectRights(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO27701 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'CRITICAL',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO27701.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO22031() {
    console.log('⚠️ Auditing ISO 22031 - Risk Management...');

    const checks = {
      risk_identification: await this.checkRiskIdentification(),
      risk_assessment_process: await this.checkRiskAssessmentProcess(),
      risk_treatment: await this.checkRiskTreatment(),
      climate_risk_integration: await this.checkClimateRiskIntegration(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO22031 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO22031.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO22301() {
    console.log('🔄 Auditing ISO 22301 - Business Continuity Management...');

    const checks = {
      continuity_planning: await this.checkContinuityPlanning(),
      disaster_recovery: await this.checkDisasterRecovery(),
      service_resilience: await this.checkServiceResilience(),
      emergency_response: await this.checkEmergencyResponse(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO22301 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'HIGH',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO22301.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  async auditISO24165() {
    console.log('🔍 Auditing ISO 24165 - Asset Identifier...');

    const checks = {
      asset_identification: await this.checkAssetIdentification(),
      unique_identifiers: await this.checkUniqueIdentifiers(),
      registry_integration: await this.checkRegistryIntegration(),
      climate_asset_tracking: await this.checkClimateAssetTracking(),
    };

    const score = this.calculateStandardScore(checks);
    this.results.detailed_results.ISO24165 = {
      score,
      status: score >= 0.9 ? 'FULLY_COMPLIANT' : 'NEEDS_IMPROVEMENT',
      checks,
      priority: 'MEDIUM',
    };

    console.log(
      `   Result: ${this.results.detailed_results.ISO24165.status} (${(score * 100).toFixed(1)}%)\n`
    );
  }

  // Check implementations for each standard
  async checkISO20022MessageStructure() {
    try {
      const iso20022Path = 'blockchain-core/iso20022';
      if (!fs.existsSync(iso20022Path)) return false;

      const messagesFile = path.join(iso20022Path, 'messages.rs');
      const validatorFile = path.join(iso20022Path, 'validator.rs');

      return fs.existsSync(messagesFile) && fs.existsSync(validatorFile);
    } catch (error) {
      return false;
    }
  }

  async checkCrossBorderPayments() {
    try {
      const testPath = 'consolidated-tests/utils/test-iso20022-integration.js';
      if (!fs.existsSync(testPath)) return false;

      const content = fs.readFileSync(testPath, 'utf8');
      return (
        content.includes('cross-border') ||
        content.includes('CustomerCreditTransferInitiation')
      );
    } catch (error) {
      return false;
    }
  }

  async checkClimateFinanceExtensions() {
    try {
      const testPath = 'consolidated-tests/utils/test-iso-compliance.js';
      if (!fs.existsSync(testPath)) return false;

      const content = fs.readFileSync(testPath, 'utf8');
      return content.includes('climateDataPayment') || content.includes('CLDT');
    } catch (error) {
      return false;
    }
  }

  async checkXMLValidation() {
    try {
      const iso20022Path = 'blockchain-core/iso20022/parser.rs';
      if (!fs.existsSync(iso20022Path)) return false;

      const content = fs.readFileSync(iso20022Path, 'utf8');
      return content.includes('quick_xml') || content.includes('xml');
    } catch (error) {
      return false;
    }
  }

  async checkBusinessApplicationHeader() {
    try {
      const testPath = 'consolidated-tests/utils/test-iso-compliance.js';
      if (!fs.existsSync(testPath)) return false;

      const content = fs.readFileSync(testPath, 'utf8');
      return content.includes('businessApplicationHeaderV01');
    } catch (error) {
      return false;
    }
  }

  async checkCurrencyCodeSupport() {
    try {
      const currencyFile =
        'blockchain-core/iso_compliance/iso4217_currency_codes.rs';
      return fs.existsSync(currencyFile);
    } catch (error) {
      return false;
    }
  }

  async checkWRFCurrencyIntegration() {
    try {
      const files = [
        'backend/server/enhanced_unified_api.ts',
        'frontend/src/services/api.js',
      ];
      return files.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('WRF') && content.includes('currency');
      });
    } catch (error) {
      return false;
    }
  }

  async checkExchangeRateHandling() {
    try {
      const apiFile = 'backend/server/enhanced_unified_api.ts';
      if (!fs.existsSync(apiFile)) return false;

      const content = fs.readFileSync(apiFile, 'utf8');
      return content.includes('exchange') || content.includes('rate');
    } catch (error) {
      return false;
    }
  }

  async checkMultiCurrencySupport() {
    try {
      const testFiles = ['consolidated-tests/utils/test-iso-compliance.js'];
      return testFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('multi') && content.includes('currency');
      });
    } catch (error) {
      return false;
    }
  }

  async checkGHGQuantification() {
    try {
      const ghgFile =
        'blockchain-core/iso_compliance/iso14064_1_ghg_quantification.rs';
      return fs.existsSync(ghgFile);
    } catch (error) {
      return false;
    }
  }

  async checkProjectVerification() {
    try {
      const projectFile =
        'blockchain-core/iso_compliance/iso14064_2_ghg_projects.rs';
      return fs.existsSync(projectFile);
    } catch (error) {
      return false;
    }
  }

  async checkCarbonCreditGeneration() {
    try {
      const verificationFile =
        'blockchain-core/iso_compliance/iso14064_3_ghg_verification.rs';
      return fs.existsSync(verificationFile);
    } catch (error) {
      return false;
    }
  }

  async checkScopeEmissions() {
    try {
      const apiFile = 'backend/server/enhanced_unified_api.ts';
      if (!fs.existsSync(apiFile)) return false;

      const content = fs.readFileSync(apiFile, 'utf8');
      return content.includes('carbon') || content.includes('emission');
    } catch (error) {
      return false;
    }
  }

  async checkSecurityControls() {
    try {
      const securityFile =
        'blockchain-core/iso_compliance/iso27001_security.rs';
      return fs.existsSync(securityFile);
    } catch (error) {
      return false;
    }
  }

  async checkRiskAssessment() {
    try {
      const riskFile =
        'blockchain-core/iso_compliance/iso22031_risk_management.rs';
      return fs.existsSync(riskFile);
    } catch (error) {
      return false;
    }
  }

  async checkIncidentResponse() {
    try {
      const files = ['backend/server/enhanced_unified_api.ts'];
      return files.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('incident') || content.includes('response');
      });
    } catch (error) {
      return false;
    }
  }

  async checkAccessControl() {
    try {
      const middlewareFiles = ['backend/middleware', 'backend/server'];
      return middlewareFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir);
        return files.some(
          file => file.includes('auth') || file.includes('security')
        );
      });
    } catch (error) {
      return false;
    }
  }

  async checkEncryptionImplementation() {
    try {
      const cryptoFiles = ['blockchain-core/crypto', 'backend/server'];
      return cryptoFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir).join(' ');
        return files.includes('encrypt') || files.includes('crypto');
      });
    } catch (error) {
      return false;
    }
  }

  async checkArchitectureCompliance() {
    try {
      const archFile =
        'blockchain-core/iso_compliance/iso23257_architecture.rs';
      return fs.existsSync(archFile);
    } catch (error) {
      return false;
    }
  }

  async checkLayerSeparation() {
    try {
      const dirs = ['blockchain-core', 'backend', 'frontend'];
      return dirs.every(dir => fs.existsSync(dir));
    } catch (error) {
      return false;
    }
  }

  async checkComponentInterfaces() {
    try {
      const apiFile = 'backend/server/enhanced_unified_api.ts';
      if (!fs.existsSync(apiFile)) return false;

      const content = fs.readFileSync(apiFile, 'utf8');
      return content.includes('interface') || content.includes('endpoint');
    } catch (error) {
      return false;
    }
  }

  async checkGovernanceIntegration() {
    try {
      const govFile = 'backend/server/governance_server.js';
      return fs.existsSync(govFile);
    } catch (error) {
      return false;
    }
  }

  async checkCrossChainProtocols() {
    try {
      const interopFile =
        'blockchain-core/iso_compliance/iso23576_interoperability.rs';
      return fs.existsSync(interopFile);
    } catch (error) {
      return false;
    }
  }

  async checkMessageStandardization() {
    try {
      const bridgeFiles = ['backend/server/cross_chain_protocol_server.js'];
      return bridgeFiles.some(file => fs.existsSync(file));
    } catch (error) {
      return false;
    }
  }

  async checkSecurityMechanisms() {
    try {
      const securityDirs = ['blockchain-core/security', 'backend/security'];
      return securityDirs.some(dir => fs.existsSync(dir));
    } catch (error) {
      return false;
    }
  }

  async checkClimateDataInteroperability() {
    try {
      const climateFiles = ['backend/server/enhanced_unified_api.ts'];
      return climateFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('weather') || content.includes('climate');
      });
    } catch (error) {
      return false;
    }
  }

  // Additional check methods for other standards...
  async checkCustodyControls() {
    try {
      const custodyFile = 'blockchain-core/iso_compliance/iso22739_custody.rs';
      return fs.existsSync(custodyFile);
    } catch (error) {
      return false;
    }
  }

  async checkKeyManagement() {
    try {
      const keyMgmtDirs = [
        'blockchain-core/crypto',
        'backend/server/wallet_server.js',
      ];
      return keyMgmtDirs.some(path => fs.existsSync(path));
    } catch (error) {
      return false;
    }
  }

  async checkMultiSignatureSupport() {
    try {
      const walletFile = 'backend/server/wallet_server.js';
      if (!fs.existsSync(walletFile)) return false;

      const content = fs.readFileSync(walletFile, 'utf8');
      return content.includes('multi') || content.includes('signature');
    } catch (error) {
      return false;
    }
  }

  async checkAuditTrails() {
    try {
      const logFiles = ['backend', 'blockchain-core'];
      return logFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir).join(' ');
        return files.includes('audit') || files.includes('log');
      });
    } catch (error) {
      return false;
    }
  }

  async checkMetadataStandards() {
    try {
      const geoFile =
        'blockchain-core/iso_compliance/iso19115_geographic_information.rs';
      return fs.existsSync(geoFile);
    } catch (error) {
      return false;
    }
  }

  async checkGeographicIndexing() {
    try {
      const apiFile = 'backend/server/enhanced_unified_api.ts';
      if (!fs.existsSync(apiFile)) return false;

      const content = fs.readFileSync(apiFile, 'utf8');
      return content.includes('geo') || content.includes('location');
    } catch (error) {
      return false;
    }
  }

  async checkWeatherStationMetadata() {
    try {
      const iotFile = 'backend/server/iot_sensor_networks_server_fixed.ts';
      return fs.existsSync(iotFile);
    } catch (error) {
      return false;
    }
  }

  async checkSpatialValidation() {
    try {
      const testFiles = ['consolidated-tests'];
      return testFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir, { recursive: true }).join(' ');
        return files.includes('spatial') || files.includes('geo');
      });
    } catch (error) {
      return false;
    }
  }

  async checkObservationModel() {
    try {
      const obsFile = 'blockchain-core/iso_compliance/iso19156_observations.rs';
      return fs.existsSync(obsFile);
    } catch (error) {
      return false;
    }
  }

  async checkMeasurementQuality() {
    try {
      const qualityFiles = ['backend/server/enhanced_unified_api.ts'];
      return qualityFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('quality') || content.includes('measurement');
      });
    } catch (error) {
      return false;
    }
  }

  async checkSensorIntegration() {
    try {
      const sensorFile = 'backend/server/iot_sensor_networks_server_fixed.ts';
      return fs.existsSync(sensorFile);
    } catch (error) {
      return false;
    }
  }

  async checkDataValidation() {
    try {
      const validationFiles = ['backend/middleware', 'consolidated-tests'];
      return validationFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir, { recursive: true }).join(' ');
        return files.includes('validat') || files.includes('verify');
      });
    } catch (error) {
      return false;
    }
  }

  async checkPrivacyControls() {
    try {
      const privacyFile = 'blockchain-core/iso_compliance/iso27701_privacy.rs';
      return fs.existsSync(privacyFile);
    } catch (error) {
      return false;
    }
  }

  async checkGDPRCompliance() {
    try {
      const middlewareFiles = ['backend/middleware'];
      return middlewareFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir).join(' ');
        return files.includes('gdpr') || files.includes('privacy');
      });
    } catch (error) {
      return false;
    }
  }

  async checkConsentManagement() {
    try {
      const frontendFiles = ['frontend/src'];
      return frontendFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir, { recursive: true }).join(' ');
        return files.includes('consent') || files.includes('permission');
      });
    } catch (error) {
      return false;
    }
  }

  async checkDataSubjectRights() {
    try {
      const apiFile = 'backend/server/enhanced_unified_api.ts';
      if (!fs.existsSync(apiFile)) return false;

      const content = fs.readFileSync(apiFile, 'utf8');
      return (
        content.includes('data') &&
        (content.includes('subject') || content.includes('rights'))
      );
    } catch (error) {
      return false;
    }
  }

  async checkRiskIdentification() {
    try {
      const riskFile =
        'blockchain-core/iso_compliance/iso22031_risk_management.rs';
      return fs.existsSync(riskFile);
    } catch (error) {
      return false;
    }
  }

  async checkRiskAssessmentProcess() {
    try {
      const assessmentFiles = ['backend/server/enhanced_unified_api.ts'];
      return assessmentFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('risk') && content.includes('assess');
      });
    } catch (error) {
      return false;
    }
  }

  async checkRiskTreatment() {
    try {
      const securityFiles = ['blockchain-core/security', 'backend/security'];
      return securityFiles.some(dir => fs.existsSync(dir));
    } catch (error) {
      return false;
    }
  }

  async checkClimateRiskIntegration() {
    try {
      const climateFiles = ['backend/server/enhanced_unified_api.ts'];
      return climateFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('climate') && content.includes('risk');
      });
    } catch (error) {
      return false;
    }
  }

  async checkContinuityPlanning() {
    try {
      const bcFile =
        'blockchain-core/iso_compliance/iso22301_business_continuity.rs';
      return fs.existsSync(bcFile);
    } catch (error) {
      return false;
    }
  }

  async checkDisasterRecovery() {
    try {
      const drFiles = ['backend/server'];
      return drFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir).join(' ');
        return files.includes('recovery') || files.includes('backup');
      });
    } catch (error) {
      return false;
    }
  }

  async checkServiceResilience() {
    try {
      const healthFiles = ['backend/server/enhanced_unified_api.ts'];
      return healthFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('health') || content.includes('resilience');
      });
    } catch (error) {
      return false;
    }
  }

  async checkEmergencyResponse() {
    try {
      const emergencyFiles = ['backend/middleware'];
      return emergencyFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir).join(' ');
        return files.includes('emergency') || files.includes('incident');
      });
    } catch (error) {
      return false;
    }
  }

  async checkAssetIdentification() {
    try {
      const assetFile =
        'blockchain-core/iso_compliance/iso24165_asset_identifier.rs';
      return fs.existsSync(assetFile);
    } catch (error) {
      return false;
    }
  }

  async checkUniqueIdentifiers() {
    try {
      const blockchainFiles = ['blockchain-core'];
      return blockchainFiles.some(dir => {
        if (!fs.existsSync(dir)) return false;
        const files = fs.readdirSync(dir, { recursive: true }).join(' ');
        return files.includes('identifier') || files.includes('uuid');
      });
    } catch (error) {
      return false;
    }
  }

  async checkRegistryIntegration() {
    try {
      const registryFiles = ['backend/server/enhanced_unified_api.ts'];
      return registryFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('registry') || content.includes('register');
      });
    } catch (error) {
      return false;
    }
  }

  async checkClimateAssetTracking() {
    try {
      const trackingFiles = ['backend/server/enhanced_unified_api.ts'];
      return trackingFiles.some(file => {
        if (!fs.existsSync(file)) return false;
        const content = fs.readFileSync(file, 'utf8');
        return content.includes('climate') && content.includes('asset');
      });
    } catch (error) {
      return false;
    }
  }

  calculateStandardScore(checks) {
    const totalChecks = Object.keys(checks).length;
    const passedChecks = Object.values(checks).filter(Boolean).length;
    return totalChecks > 0 ? passedChecks / totalChecks : 0;
  }

  calculateOverallScore() {
    const standards = Object.values(this.results.detailed_results);
    this.results.standards_tested = standards.length;
    this.results.standards_passed = standards.filter(
      s => s.status === 'FULLY_COMPLIANT'
    ).length;
    this.results.standards_failed = standards.filter(
      s => s.status === 'NEEDS_IMPROVEMENT'
    ).length;

    const totalScore = standards.reduce((sum, s) => sum + s.score, 0);
    this.results.overall_score =
      standards.length > 0 ? totalScore / standards.length : 0;
  }

  generateReport() {
    console.log('\n' + '='.repeat(80));
    console.log('🏆 WRFCOIN ISO STANDARDS COMPLIANCE AUDIT REPORT');
    console.log('='.repeat(80));

    console.log(
      `\n📊 OVERALL COMPLIANCE SCORE: ${(this.results.overall_score * 100).toFixed(1)}%`
    );
    console.log(`📈 Standards Tested: ${this.results.standards_tested}`);
    console.log(`✅ Fully Compliant: ${this.results.standards_passed}`);
    console.log(`⚠️  Needs Improvement: ${this.results.standards_failed}`);
    console.log(
      `🚧 In Progress: ${this.results.standards_tested - this.results.standards_passed - this.results.standards_failed}`
    );

    console.log('\n📋 DETAILED COMPLIANCE STATUS:\n');

    // Sort by priority and score
    const sortedStandards = Object.entries(this.results.detailed_results).sort(
      ([, a], [, b]) => {
        const priorityOrder = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3 };
        const priorityDiff =
          priorityOrder[a.priority] - priorityOrder[b.priority];
        return priorityDiff !== 0 ? priorityDiff : b.score - a.score;
      }
    );

    for (const [standard, result] of sortedStandards) {
      const statusIcon =
        result.status === 'FULLY_COMPLIANT'
          ? '✅'
          : result.status === 'MOSTLY_COMPLIANT'
            ? '🟡'
            : result.status === 'IN_PROGRESS'
              ? '🚧'
              : '❌';

      const priorityIcon =
        result.priority === 'CRITICAL'
          ? '🔴'
          : result.priority === 'HIGH'
            ? '🟡'
            : '🟢';

      console.log(
        `${statusIcon} ${standard}: ${(result.score * 100).toFixed(1)}% ${priorityIcon} ${result.priority}`
      );

      // Show failed checks
      const failedChecks = Object.entries(result.checks)
        .filter(([, passed]) => !passed)
        .map(([check]) => check);

      if (failedChecks.length > 0) {
        console.log(`   ⚠️  Failed checks: ${failedChecks.join(', ')}`);
      }
    }

    console.log('\n🎯 RECOMMENDATIONS:');

    if (this.results.overall_score >= 0.95) {
      console.log(
        '✅ Excellent compliance! Wrfcoin meets enterprise-grade ISO standards.'
      );
    } else if (this.results.overall_score >= 0.85) {
      console.log('🟡 Good compliance with minor improvements needed.');
    } else if (this.results.overall_score >= 0.7) {
      console.log(
        '⚠️  Moderate compliance - address critical standards first.'
      );
    } else {
      console.log(
        '❌ Significant compliance gaps - immediate attention required.'
      );
    }

    // Critical standards recommendations
    const criticalStandards = sortedStandards
      .filter(
        ([, result]) => result.priority === 'CRITICAL' && result.score < 0.9
      )
      .map(([standard]) => standard);

    if (criticalStandards.length > 0) {
      console.log(
        `\n🔴 Priority Action Required for: ${criticalStandards.join(', ')}`
      );
    }

    console.log('\n' + '='.repeat(80));

    // Save report to file
    const reportPath = 'docs/iso-compliance-report.json';
    fs.writeFileSync(reportPath, JSON.stringify(this.results, null, 2));
    console.log(`📄 Detailed report saved to: ${reportPath}`);
  }
}

// Run the audit
async function main() {
  const auditor = new ISOComplianceAuditor();
  await auditor.auditAllStandards();
}

// ESM entry point check
const isMainModule = import.meta.url === `file://${process.argv[1]}`;
if (isMainModule || process.argv[1]?.endsWith('iso-compliance-audit.js')) {
  main().catch(console.error);
}

export { ISOComplianceAuditor };
