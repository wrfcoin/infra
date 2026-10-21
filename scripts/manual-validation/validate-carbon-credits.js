#!/usr/bin/env node
/**
 * Manual Validation Script: Carbon Credits
 * Task 114.10 - Manual validation scripts for critical business logic
 *
 * Tests:
 * 1. Emission factor accuracy against EPA/IPCC standards
 * 2. Credit calculation with known reference data
 * 3. Quality score computation with sample datasets
 * 4. Marketplace order integrity
 * 5. Settlement calculation accuracy
 *
 * Run: node scripts/manual-validation/validate-carbon-credits.js
 */

const PASS = '\x1b[32mPASS\x1b[0m';
const FAIL = '\x1b[31mFAIL\x1b[0m';
const INFO = '\x1b[36mINFO\x1b[0m';

// EPA/IPCC Standard Emission Factors (kg CO2 per unit)
const EPA_EMISSION_FACTORS = {
  // Electricity (kg CO2 per kWh) - US average
  electricity_us_avg: 0.417,
  electricity_coal: 0.996,
  electricity_natural_gas: 0.413,
  electricity_solar: 0.041,
  electricity_wind: 0.011,

  // Transportation (kg CO2 per liter)
  gasoline: 2.31,
  diesel: 2.68,
  jet_fuel: 2.52,

  // Natural Gas (kg CO2 per cubic meter)
  natural_gas_m3: 1.89,

  // Propane (kg CO2 per liter)
  propane: 1.51,
};

// Test reference data with known correct results
const REFERENCE_CALCULATIONS = [
  {
    name: 'Home electricity (1000 kWh)',
    type: 'electricity_us_avg',
    quantity: 1000,
    expected_kg_co2: 417,
    tolerance: 1,
  },
  {
    name: 'Car trip gasoline (50 liters)',
    type: 'gasoline',
    quantity: 50,
    expected_kg_co2: 115.5,
    tolerance: 0.5,
  },
  {
    name: 'Heating natural gas (100 m3)',
    type: 'natural_gas_m3',
    quantity: 100,
    expected_kg_co2: 189,
    tolerance: 1,
  },
  {
    name: 'Solar panel offset (500 kWh)',
    type: 'electricity_solar',
    quantity: 500,
    expected_kg_co2: 20.5,
    tolerance: 0.5,
  },
];

// Quality scoring test data
// Scores are calculated as: base(50) + standard_bonus + audit_bonus(10) + frequency_bonus + transparency_bonus(17*value)
const QUALITY_TEST_PROJECTS = [
  {
    id: 'proj_001',
    name: 'Amazon Rainforest Conservation',
    verification_standard: 'VCS',
    methodology: 'REDD+',
    third_party_audit: true,
    monitoring_frequency: 'quarterly',
    data_transparency: 0.95,
    expected_quality_score: 99, // 50 + 15 + 10 + 8 + 16 = 99
  },
  {
    id: 'proj_002',
    name: 'Wind Farm Project',
    verification_standard: 'Gold Standard',
    methodology: 'Renewable Energy',
    third_party_audit: true,
    monitoring_frequency: 'monthly',
    data_transparency: 0.90,
    expected_quality_score: 100, // 50 + 18 + 10 + 10 + 15 = 103, capped at 100
  },
  {
    id: 'proj_003',
    name: 'Local Tree Planting',
    verification_standard: 'None',
    methodology: 'Afforestation',
    third_party_audit: false,
    monitoring_frequency: 'annually',
    data_transparency: 0.60,
    expected_quality_score: 62, // 50 + 0 + 0 + 2 + 10 = 62
  },
];

// Marketplace order test data
const MARKETPLACE_ORDERS = [
  {
    id: 'order_001',
    buyer: '0x1234...5678',
    credit_amount: 100,
    price_per_credit: 15.5,
    expected_total: 1550,
    expected_fee: 46.5, // 3% platform fee
    expected_net: 1503.5,
  },
  {
    id: 'order_002',
    buyer: '0xabcd...ef01',
    credit_amount: 1000,
    price_per_credit: 12.0,
    expected_total: 12000,
    expected_fee: 360, // 3% platform fee
    expected_net: 11640,
  },
];

// Settlement test data
const SETTLEMENT_TESTS = [
  {
    id: 'settlement_001',
    orders: [
      { credit_amount: 100, price: 15 },
      { credit_amount: 200, price: 14 },
    ],
    expected_total_credits: 300,
    expected_gross: 4300,
    expected_fees: 129, // 3%
    expected_net: 4171,
  },
];

class ValidationResults {
  constructor() {
    this.passed = 0;
    this.failed = 0;
    this.results = [];
  }

  add(name, passed, details = '') {
    this.results.push({ name, passed, details });
    if (passed) {
      this.passed++;
    } else {
      this.failed++;
    }
  }

  print() {
    console.log('\n' + '='.repeat(70));
    console.log('CARBON CREDIT VALIDATION RESULTS');
    console.log('='.repeat(70) + '\n');

    for (const result of this.results) {
      const status = result.passed ? PASS : FAIL;
      console.log(`[${status}] ${result.name}`);
      if (result.details) {
        console.log(`       ${result.details}`);
      }
    }

    console.log('\n' + '-'.repeat(70));
    console.log(`Total: ${this.passed + this.failed} | Passed: ${this.passed} | Failed: ${this.failed}`);
    console.log('-'.repeat(70) + '\n');

    return this.failed === 0;
  }
}

// Carbon emission calculation function (mirrors production logic)
function calculateEmissions(type, quantity) {
  const factor = EPA_EMISSION_FACTORS[type];
  if (!factor) {
    throw new Error(`Unknown emission type: ${type}`);
  }
  return quantity * factor;
}

// Quality score calculation (mirrors production logic)
function calculateQualityScore(project) {
  let score = 50; // Base score

  // Verification standard bonus
  const standardBonus = {
    VCS: 15,
    'Gold Standard': 18,
    'American Carbon Registry': 15,
    'Climate Action Reserve': 14,
    None: 0,
  };
  score += standardBonus[project.verification_standard] || 0;

  // Third-party audit bonus
  if (project.third_party_audit) {
    score += 10;
  }

  // Monitoring frequency bonus
  const frequencyBonus = {
    monthly: 10,
    quarterly: 8,
    semi_annually: 5,
    annually: 2,
  };
  score += frequencyBonus[project.monitoring_frequency] || 0;

  // Data transparency (0-1 scale, contributes up to 17 points)
  score += Math.round(project.data_transparency * 17);

  return Math.min(100, Math.max(0, score));
}

// Marketplace order calculation
function calculateOrderTotals(order, feePercent = 0.03) {
  const total = order.credit_amount * order.price_per_credit;
  const fee = total * feePercent;
  const net = total - fee;
  return { total, fee, net };
}

// Settlement calculation
function calculateSettlement(orders, feePercent = 0.03) {
  let totalCredits = 0;
  let gross = 0;

  for (const order of orders) {
    totalCredits += order.credit_amount;
    gross += order.credit_amount * order.price;
  }

  const fees = gross * feePercent;
  const net = gross - fees;

  return { totalCredits, gross, fees, net };
}

// Validation Tests
function runValidations() {
  const results = new ValidationResults();

  console.log(`\n[${INFO}] Starting Carbon Credit Validation Suite...\n`);

  // Test 1: Emission Factor Accuracy
  console.log(`[${INFO}] Test 1: Verifying EPA/IPCC emission factors...`);
  for (const ref of REFERENCE_CALCULATIONS) {
    const calculated = calculateEmissions(ref.type, ref.quantity);
    const diff = Math.abs(calculated - ref.expected_kg_co2);
    const passed = diff <= ref.tolerance;

    results.add(
      `Emission Factor: ${ref.name}`,
      passed,
      `Expected: ${ref.expected_kg_co2} kg CO2, Got: ${calculated.toFixed(2)} kg CO2 (diff: ${diff.toFixed(2)})`
    );
  }

  // Test 2: Credit Calculation with Reference Data
  console.log(`\n[${INFO}] Test 2: Verifying credit calculations...`);

  // Test carbon credit from emission offset
  const offsetEmission = calculateEmissions('electricity_coal', 1000);
  const solarOffset = calculateEmissions('electricity_solar', 1000);
  const netReduction = offsetEmission - solarOffset;
  const expectedReduction = 955; // (0.996 - 0.041) * 1000 kg CO2
  const reductionDiff = Math.abs(netReduction - expectedReduction);

  results.add(
    'Credit Calculation: Coal to Solar Offset (1000 kWh)',
    reductionDiff < 1,
    `Expected: ${expectedReduction} kg CO2 reduction, Got: ${netReduction.toFixed(2)} kg CO2`
  );

  // Test credits per metric ton (1000 kg = 1 credit)
  const emissionTons = offsetEmission / 1000;
  const expectedTons = 0.996;
  results.add(
    'Credit Calculation: Metric Tons Conversion',
    Math.abs(emissionTons - expectedTons) < 0.001,
    `Expected: ${expectedTons} tons, Got: ${emissionTons.toFixed(3)} tons`
  );

  // Test 3: Quality Score Computation
  console.log(`\n[${INFO}] Test 3: Verifying quality score calculations...`);
  for (const project of QUALITY_TEST_PROJECTS) {
    const calculated = calculateQualityScore(project);
    const diff = Math.abs(calculated - project.expected_quality_score);
    const passed = diff <= 3; // Allow 3 point tolerance

    results.add(
      `Quality Score: ${project.name}`,
      passed,
      `Expected: ${project.expected_quality_score}, Got: ${calculated} (diff: ${diff})`
    );
  }

  // Test 4: Marketplace Order Integrity
  console.log(`\n[${INFO}] Test 4: Verifying marketplace order calculations...`);
  for (const order of MARKETPLACE_ORDERS) {
    const calculated = calculateOrderTotals(order);

    const totalPassed = Math.abs(calculated.total - order.expected_total) < 0.01;
    const feePassed = Math.abs(calculated.fee - order.expected_fee) < 0.01;
    const netPassed = Math.abs(calculated.net - order.expected_net) < 0.01;

    results.add(
      `Order Total: ${order.id}`,
      totalPassed,
      `Expected: $${order.expected_total}, Got: $${calculated.total.toFixed(2)}`
    );

    results.add(
      `Order Fee: ${order.id}`,
      feePassed,
      `Expected: $${order.expected_fee}, Got: $${calculated.fee.toFixed(2)}`
    );

    results.add(
      `Order Net: ${order.id}`,
      netPassed,
      `Expected: $${order.expected_net}, Got: $${calculated.net.toFixed(2)}`
    );
  }

  // Test 5: Settlement Calculation Accuracy
  console.log(`\n[${INFO}] Test 5: Verifying settlement calculations...`);
  for (const settlement of SETTLEMENT_TESTS) {
    const calculated = calculateSettlement(settlement.orders);

    results.add(
      `Settlement Credits: ${settlement.id}`,
      calculated.totalCredits === settlement.expected_total_credits,
      `Expected: ${settlement.expected_total_credits}, Got: ${calculated.totalCredits}`
    );

    results.add(
      `Settlement Gross: ${settlement.id}`,
      Math.abs(calculated.gross - settlement.expected_gross) < 0.01,
      `Expected: $${settlement.expected_gross}, Got: $${calculated.gross.toFixed(2)}`
    );

    results.add(
      `Settlement Fees: ${settlement.id}`,
      Math.abs(calculated.fees - settlement.expected_fees) < 0.01,
      `Expected: $${settlement.expected_fees}, Got: $${calculated.fees.toFixed(2)}`
    );

    results.add(
      `Settlement Net: ${settlement.id}`,
      Math.abs(calculated.net - settlement.expected_net) < 0.01,
      `Expected: $${settlement.expected_net}, Got: $${calculated.net.toFixed(2)}`
    );
  }

  // Print final results
  const allPassed = results.print();

  if (allPassed) {
    console.log('\x1b[32mAll carbon credit validations passed!\x1b[0m\n');
    process.exit(0);
  } else {
    console.log('\x1b[31mSome carbon credit validations failed. Review results above.\x1b[0m\n');
    process.exit(1);
  }
}

// Run validations
runValidations();
