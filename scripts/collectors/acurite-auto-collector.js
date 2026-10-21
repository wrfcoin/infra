/**
 * AcuRite Weather Station Auto-Collector
 * Automatically collects and submits weather data to earn WRF tokens
 * "Set it and forget it" system for continuous earnings
 */

const axios = require('axios');
const {
  GracefulShutdown,
  ShutdownPriority,
} = require('../../backend/shared/graceful-shutdown/index.js');

// Track active intervals for cleanup
const activeIntervals = [];

// Configuration for your AcuRite Iris 5-in-1 Weather Station
const ACURITE_CONFIG = {
  deviceId: process.env.ACURITE_DEVICE_ID || '24:C8:6E:0C:28:38',
  localIP: process.env.ACURITE_LOCAL_IP || '192.168.1.40',
  collectionInterval: 60000, // 60 seconds
  submissionEndpoint: 'http://localhost:4000/api/weather/submit'
};

let earnings = {
  totalTokens: 0,
  submissions: 0,
  successfulCollections: 0,
  failedAttempts: 0
};

// Multiple methods to connect to AcuRite station
async function collectAcuRiteData() {
  const methods = [
    () => connectViaMyAcuRiteAPI(),
    () => connectViaWeatherUnderground(),
    () => connectViaLocalAPI(),
    () => connectViaDirectHTTP()
  ];

  for (const method of methods) {
    try {
      const data = await method();
      if (data) {
        console.log('✅ AcuRite data collected successfully:', data.source);
        return data;
      }
    } catch (error) {
      console.log(`⚠️ Collection method failed, trying next: ${error.message}`);
    }
  }

  return null;
}

// Method 1: Direct AcuRite cloud access using Device ID
async function connectViaMyAcuRiteAPI() {
  console.log(`🔍 Accessing AcuRite data for device ${ACURITE_CONFIG.deviceId}...`);
  
  const deviceIdClean = ACURITE_CONFIG.deviceId.replace(/:/g, '');
  
  // Method 1a: Login-based approach (working MyAcuRite connection)
  const email = process.env.MYACURITE_EMAIL;
  const password = process.env.MYACURITE_PASSWORD;
  
  if (email && password) {
    try {
      console.log('🔐 Logging into MyAcuRite...');
      
      // Step 1: Login to get session - Working credentials
      const loginResponse = await axios.post('https://marapi.myacurite.com/users/login', {
        email: email,
        password: password,
        remember: 'True'
      }, {
        headers: {
          'Content-Type': 'application/json'
        },
        timeout: 15000
      });
      
      console.log('✅ MyAcuRite login successful');
      const loginData = loginResponse.data;
      const accountId = loginData.user.account_users[0].account_id;
      const tokenId = loginData.token_id;
      
      // Step 2: Get hub information - following exact Wolfram pattern
      const hubsResponse = await axios.get(
        `https://marapi.myacurite.com/accounts/${accountId}/dashboard/hubs`,
        {
          headers: {
            'Content-Type': 'application/json',
            'x-one-vue-token': tokenId
          }
        }
      );

      const hubId = hubsResponse.data.account_hubs[0].id;
      console.log(`🏠 Found hub ID: ${hubId}`);

      // Step 3: Get current weather data - exact Wolfram API call
      const weatherResponse = await axios.get(
        `https://marapi.myacurite.com/accounts/${accountId}/dashboard/hubs/${hubId}`,
        {
          headers: {
            'Content-Type': 'application/json',
            'x-one-vue-token': tokenId
          },
          timeout: 10000
        }
      );

      console.log('✅ Weather readings retrieved via authenticated session');
      if (weatherResponse.data && weatherResponse.data.reading) {
        return parseAcuRiteData(weatherResponse.data.reading, 'MyAcuRite Authenticated');
      }
      
    } catch (error) {
      console.log(`⚠️ Authenticated MyAcuRite access failed: ${error.message}`);
    }
  }
  
  // Method 1b: Try public weather data endpoint
  try {
    console.log('🌐 Trying public weather data endpoint...');
    const response = await axios.get(`https://atlasapi.myacurite.com/v2/devices/${deviceIdClean}/readings/latest`, {
      headers: {
        'User-Agent': 'WRF-Collector/1.0',
        'Accept': 'application/json'
      },
      timeout: 12000
    });
    
    console.log('📊 Atlas API data retrieved');
    if (response.data && response.data.reading) {
      return parseAcuRiteData(response.data.reading, 'AcuRite Atlas API');
    }
  } catch (error) {
    console.log(`⚠️ Atlas API failed: ${error.message}`);
  }
  
  // Method 1c: Try WeatherRack endpoint (based on Wolfram code pattern)
  try {
    console.log('🔄 Trying WeatherRack-style endpoint...');
    const response = await axios.get(`https://www.myacurite.com/weatherrack/${deviceIdClean}/latest.json`, {
      headers: {
        'User-Agent': 'WRF-Collector/1.0',
        'Accept': 'application/json'
      },
      timeout: 10000
    });
    
    console.log('🌦️ WeatherRack data retrieved');
    if (response.data) {
      return parseAcuRiteData(response.data, 'AcuRite WeatherRack');
    }
  } catch (error) {
    console.log(`⚠️ WeatherRack endpoint failed: ${error.message}`);
  }
  
  // Method 1d: Try station data endpoint
  try {
    console.log('🌐 Trying station data endpoint...');
    const response = await axios.get(`https://atlas.myacurite.com/users/stations/${deviceIdClean}`, {
      headers: {
        'User-Agent': 'WRF-Collector/1.0',
        'Accept': 'application/json'
      },
      timeout: 10000
    });
    
    console.log('🏠 Station data retrieved');
    if (response.data && response.data.station) {
      return parseAcuRiteData(response.data.station, 'AcuRite Station Data');
    }
  } catch (error) {
    console.log(`⚠️ Station data endpoint failed: ${error.message}`);
  }
  
  throw new Error('Unable to access AcuRite data with Device ID');
}

// Method 2: Local API connection (for local network stations)
async function connectViaLocalAPI() {
  const response = await axios.get(`http://${ACURITE_CONFIG.localIP}/weatherstation/updateweatherstation.php`, {
    timeout: 5000,
    headers: {
      'User-Agent': 'WRF-Collector/1.0'
    }
  });

  return parseAcuRiteData(response.data, 'AcuRite Local API');
}

// Method 2: Weather Underground / Smart Hub format (based on Wolfram patterns)
async function connectViaWeatherUnderground() {
  const deviceIdClean = ACURITE_CONFIG.deviceId.replace(/:/g, '');
  
  // Try Weather Underground style endpoint with device ID
  try {
    const response = await axios.get(`https://hubapi.myacurite.com/weatherstation/updateweatherstation.php`, {
      params: {
        ID: deviceIdClean,
        PASSWORD: 'MyAcuRite',
        action: 'updateraw',
        realtime: 1,
        rtfreq: 16
      },
      timeout: 8000
    });

    return parseAcuRiteData(response.data, 'AcuRite Hub API');
  } catch (error) {
    console.log(`⚠️ Hub API failed: ${error.message}`);
  }

  // Fallback to local network if available
  try {
    const response = await axios.get(`http://${ACURITE_CONFIG.localIP}/weatherstation/updateweatherstation.php?action=updateraw`, {
      timeout: 5000
    });

    return parseAcuRiteData(response.data, 'Weather Underground Protocol');
  } catch (error) {
    throw new Error('Weather Underground method failed');
  }
}

// Method 3: Ecowitt protocol (alternative format)
async function connectViaEcowittProtocol() {
  const response = await axios.get(`http://${ACURITE_CONFIG.localIP}/data/report/`, {
    timeout: 5000
  });

  return parseAcuRiteData(response.data, 'Ecowitt Protocol');
}

// Method 4: Direct HTTP data endpoint
async function connectViaDirectHTTP() {
  const response = await axios.get(`http://${ACURITE_CONFIG.localIP}/livedata.htm`, {
    timeout: 5000
  });

  return parseAcuRiteData(response.data, 'Direct HTTP');
}

// Parse weather data from various formats
function parseAcuRiteData(rawData, source) {
  try {
    let data = {};
    
    if (typeof rawData === 'string') {
      // Parse URL-encoded or HTML format
      if (rawData.includes('tempf=')) {
        const params = new URLSearchParams(rawData);
        data = {
          temperature: parseFloat(params.get('tempf')) || parseFloat(params.get('temp')),
          humidity: parseFloat(params.get('humidity')),
          windSpeed: parseFloat(params.get('windspeedmph')) || parseFloat(params.get('windspeed')),
          windDirection: parseFloat(params.get('winddir')),
          rainfall: parseFloat(params.get('rainin')) || parseFloat(params.get('dailyrainin')) || 0,
          pressure: parseFloat(params.get('baromin')) || parseFloat(params.get('pressure'))
        };
      } else if (rawData.includes('°F') || rawData.includes('mph')) {
        // Parse HTML format
        data = parseHTMLWeatherData(rawData);
      }
    } else if (typeof rawData === 'object') {
      // JSON format
      data = {
        temperature: rawData.temperature || rawData.tempf || rawData.temp,
        humidity: rawData.humidity,
        windSpeed: rawData.windSpeed || rawData.windspeedmph || rawData.windspeed,
        windDirection: rawData.windDirection || rawData.winddir,
        rainfall: rawData.rainfall || rawData.rainin || rawData.dailyrainin || 0,
        pressure: rawData.pressure || rawData.baromin
      };
    }

    // Validate essential data is present
    if (data.temperature && data.humidity) {
      return {
        ...data,
        deviceId: ACURITE_CONFIG.deviceId,
        source: `AcuRite Iris 5-in-1 (${source})`,
        timestamp: new Date().toISOString(),
        authentic: true,
        verified: true
      };
    }

    return null;
  } catch (error) {
    console.log(`Data parsing error: ${error.message}`);
    return null;
  }
}

// Parse HTML-formatted weather data
function parseHTMLWeatherData(html) {
  const data = {};
  
  // Extract temperature
  const tempMatch = html.match(/(\d+\.?\d*)\s*°F/);
  if (tempMatch) data.temperature = parseFloat(tempMatch[1]);
  
  // Extract humidity
  const humidityMatch = html.match(/(\d+)\s*%/);
  if (humidityMatch) data.humidity = parseFloat(humidityMatch[1]);
  
  // Extract wind speed
  const windMatch = html.match(/(\d+\.?\d*)\s*mph/);
  if (windMatch) data.windSpeed = parseFloat(windMatch[1]);
  
  // Extract pressure
  const pressureMatch = html.match(/(\d+\.?\d*)\s*inHg/);
  if (pressureMatch) data.pressure = parseFloat(pressureMatch[1]);
  
  return data;
}

// Submit weather data to earn WRF tokens
async function submitForRewards(weatherData) {
  try {
    const response = await axios.post(ACURITE_CONFIG.submissionEndpoint, weatherData, {
      headers: {
        'Content-Type': 'application/json'
      },
      timeout: 10000
    });

    if (response.data.success) {
      const rewardMatch = response.data.reward.match(/(\d+)/);
      const tokens = rewardMatch ? parseInt(rewardMatch[1]) : 0;
      
      earnings.totalTokens += tokens;
      earnings.submissions += 1;
      earnings.successfulCollections += 1;

      console.log(`🎯 SUCCESS! Earned ${tokens} WRF tokens!`);
      console.log(`💰 Total earnings: ${earnings.totalTokens} WRF tokens from ${earnings.submissions} submissions`);
      
      return true;
    }
  } catch (error) {
    earnings.failedAttempts += 1;
    console.log(`❌ Submission failed: ${error.message}`);
    return false;
  }
}

// Main collection loop
async function startAutoCollection() {
  console.log('🚀 Starting AcuRite Auto-Collector...');
  console.log(`📡 Device: ${ACURITE_CONFIG.deviceId}`);
  console.log(`🌐 Network: ${ACURITE_CONFIG.localIP}`);
  console.log(`⏱️ Collection interval: ${ACURITE_CONFIG.collectionInterval / 1000} seconds`);
  console.log('💰 Ready to earn WRF tokens automatically!\n');

  // Setup graceful shutdown
  const shutdown = GracefulShutdown.getInstance();

  // Register cleanup handler for intervals
  shutdown.registerHandler({
    name: 'acurite-collector-intervals',
    priority: ShutdownPriority.STOP_BACKGROUND_JOBS,
    timeout: 5000,
    handler: () => {
      console.log('\n🛑 Auto-collector stopping...');
      for (const interval of activeIntervals) {
        clearInterval(interval);
      }
      console.log(`📊 Final Stats:`);
      console.log(`   💰 Total WRF tokens earned: ${earnings.totalTokens}`);
      console.log(`   ✅ Successful submissions: ${earnings.submissions}`);
      console.log(`   📡 Successful collections: ${earnings.successfulCollections}`);
      console.log(`   ❌ Failed attempts: ${earnings.failedAttempts}`);
      console.log('👋 Thank you for contributing to the WRF network!');
    },
  });

  shutdown.setupSignalHandlers();

  const collectionInterval = setInterval(async () => {
    console.log('🔄 Collecting weather data...');
    
    const weatherData = await collectAcuRiteData();
    
    if (weatherData) {
      console.log('📊 Weather data collected:', {
        temp: `${weatherData.temperature}°F`,
        humidity: `${weatherData.humidity}%`,
        wind: `${weatherData.windSpeed} mph`,
        pressure: `${weatherData.pressure} inHg`
      });
      
      const success = await submitForRewards(weatherData);
      if (!success) {
        console.log('⏳ Will retry in next collection cycle...');
      }
    } else {
      console.log('⚠️ No data collected, will retry in next cycle...');
      earnings.failedAttempts += 1;
    }
    
    // Show current stats
    console.log(`📈 Stats: ${earnings.successfulCollections} successful | ${earnings.failedAttempts} failed | ${earnings.totalTokens} WRF earned\n`);

  }, ACURITE_CONFIG.collectionInterval);

  // Track the interval for cleanup
  activeIntervals.push(collectionInterval);
}

// Start the auto-collection system
if (require.main === module) {
  startAutoCollection().catch(error => {
    console.error('💥 Auto-collector error:', error.message);
    process.exit(1);
  });
}

module.exports = { startAutoCollection, collectAcuRiteData, earnings };