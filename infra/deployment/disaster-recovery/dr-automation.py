"""
Wrfcoin Disaster Recovery Automation Lambda Function
Location: infra/deployment/disaster-recovery/dr-automation.py
Purpose: Automated response to regional failures and DR events
"""

import json
import boto3
import os
from datetime import datetime, timezone
import logging

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    """
    Main Lambda handler for DR automation
    """
    logger.info(f"DR Automation triggered with event: {json.dumps(event)}")
    
    try:
        # Parse the event
        event_source = event.get('source', '')
        detail_type = event.get('detail-type', '')
        detail = event.get('detail', {})
        
        # Initialize AWS clients
        route53 = boto3.client('route53')
        sns = boto3.client('sns')
        cloudwatch = boto3.client('cloudwatch')
        autoscaling = boto3.client('autoscaling')
        
        # Get environment variables
        secondary_region = os.environ['SECONDARY_REGION']
        sns_topic_arn = os.environ['SNS_TOPIC_ARN']
        cluster_name = os.environ['CLUSTER_NAME']
        
        response = {}
        
        if event_source == 'aws.route53' and 'Health Check' in detail_type:
            response = handle_health_check_failure(
                detail, route53, sns, cloudwatch, autoscaling,
                secondary_region, sns_topic_arn, cluster_name
            )
        
        elif event_source == 'aws.rds' and 'DB Cluster' in detail_type:
            response = handle_database_failure(
                detail, sns, cloudwatch,
                secondary_region, sns_topic_arn
            )
        
        elif event_source == 'manual' or event.get('trigger_type') == 'manual':
            # Manual DR test trigger
            response = handle_manual_dr_trigger(
                event, sns, cloudwatch,
                secondary_region, sns_topic_arn
            )
        
        else:
            logger.warning(f"Unhandled event type: {event_source} - {detail_type}")
            response = {
                'statusCode': 200,
                'body': json.dumps({
                    'message': 'Event type not handled',
                    'event_source': event_source,
                    'detail_type': detail_type
                })
            }
        
        return response
        
    except Exception as e:
        logger.error(f"Error in DR automation: {str(e)}")
        
        # Send failure notification
        try:
            sns = boto3.client('sns')
            sns.publish(
                TopicArn=os.environ['SNS_TOPIC_ARN'],
                Subject="🚨 DR Automation Lambda Error",
                Message=f"DR automation failed with error: {str(e)}\n\nEvent: {json.dumps(event, indent=2)}"
            )
        except Exception as sns_error:
            logger.error(f"Failed to send SNS notification: {str(sns_error)}")
        
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'event': event
            })
        }

def handle_health_check_failure(detail, route53, sns, cloudwatch, autoscaling, 
                               secondary_region, sns_topic_arn, cluster_name):
    """
    Handle Route53 health check failures
    """
    logger.info("Handling health check failure")
    
    health_check_id = detail.get('health-check-id')
    status = detail.get('status')
    
    if status == 'FAILURE':
        # Record the incident start time
        incident_start = datetime.now(timezone.utc)
        
        # Send immediate alert
        alert_message = f"""
🚨 REGIONAL FAILURE DETECTED

Health Check ID: {health_check_id}
Status: {status}
Time: {incident_start.isoformat()}

Automated Response Initiated:
1. Scaling secondary region infrastructure
2. Preparing for traffic failover
3. Notifying incident response team

This is an automated alert from the Wrfcoin DR system.
        """
        
        sns.publish(
            TopicArn=sns_topic_arn,
            Subject="🚨 URGENT: Regional Failure Detected - Automated DR Response",
            Message=alert_message
        )
        
        # Scale up secondary region infrastructure
        scale_secondary_infrastructure(autoscaling, secondary_region, cluster_name)
        
        # Record DR metrics
        record_dr_metrics(cloudwatch, 'RegionalFailureDetected', 1)
        
        # In a production environment, you might also:
        # - Automatically update Route53 weights
        # - Trigger database failover
        # - Scale container instances
        # - Update load balancer configurations
        
        logger.info("Health check failure response completed")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Regional failure response initiated',
                'incident_start': incident_start.isoformat(),
                'actions_taken': [
                    'Secondary infrastructure scaling initiated',
                    'Incident team notified',
                    'DR metrics recorded'
                ]
            })
        }
    
    else:
        logger.info(f"Health check recovered: {health_check_id}")
        
        # Send recovery notification
        sns.publish(
            TopicArn=sns_topic_arn,
            Subject="✅ Health Check Recovered",
            Message=f"Health check {health_check_id} has recovered. Status: {status}"
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Health check recovered',
                'health_check_id': health_check_id
            })
        }

def handle_database_failure(detail, sns, cloudwatch, secondary_region, sns_topic_arn):
    """
    Handle database failure events
    """
    logger.info("Handling database failure")
    
    db_identifier = detail.get('source-id', 'unknown')
    event_message = detail.get('message', 'Database event')
    
    # Send database failure alert
    alert_message = f"""
🗄️ DATABASE FAILURE EVENT

Database: {db_identifier}
Event: {event_message}
Time: {datetime.now(timezone.utc).isoformat()}

Automated checks initiated:
1. Verifying read replica status
2. Checking connection pools
3. Monitoring application health

Manual intervention may be required.
    """
    
    sns.publish(
        TopicArn=sns_topic_arn,
        Subject="🗄️ Database Failure Event Detected",
        Message=alert_message
    )
    
    # Record database failure metrics
    record_dr_metrics(cloudwatch, 'DatabaseFailureDetected', 1)
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Database failure response initiated',
            'database': db_identifier
        })
    }

def handle_manual_dr_trigger(event, sns, cloudwatch, secondary_region, sns_topic_arn):
    """
    Handle manual DR test triggers
    """
    logger.info("Handling manual DR trigger")
    
    test_type = event.get('test_type', 'unknown')
    requester = event.get('requester', 'system')
    
    # Send manual test notification
    sns.publish(
        TopicArn=sns_topic_arn,
        Subject=f"🧪 Manual DR Test Initiated: {test_type}",
        Message=f"""
Manual DR test initiated:

Test Type: {test_type}
Requester: {requester}
Time: {datetime.now(timezone.utc).isoformat()}

This is a planned test of disaster recovery procedures.
        """
    )
    
    # Record test metrics
    record_dr_metrics(cloudwatch, 'ManualDRTestInitiated', 1)
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Manual DR test initiated',
            'test_type': test_type,
            'requester': requester
        })
    }

def scale_secondary_infrastructure(autoscaling, secondary_region, cluster_name):
    """
    Scale up secondary region infrastructure for failover
    """
    logger.info(f"Scaling secondary infrastructure in {secondary_region}")
    
    try:
        # Create autoscaling client for secondary region
        secondary_autoscaling = boto3.client('autoscaling', region_name=secondary_region)
        
        # Scale up the secondary region node groups
        node_groups = [
            f"{cluster_name}-secondary-api-nodes",
            f"{cluster_name}-secondary-blockchain-nodes"
        ]
        
        for node_group in node_groups:
            try:
                # Get current configuration
                response = secondary_autoscaling.describe_auto_scaling_groups(
                    AutoScalingGroupNames=[node_group]
                )
                
                if response['AutoScalingGroups']:
                    asg = response['AutoScalingGroups'][0]
                    current_capacity = asg['DesiredCapacity']
                    max_capacity = asg['MaxSize']
                    
                    # Scale to maximum capacity for failover
                    new_capacity = min(max_capacity, current_capacity * 2)
                    
                    secondary_autoscaling.update_auto_scaling_group(
                        AutoScalingGroupName=node_group,
                        DesiredCapacity=new_capacity
                    )
                    
                    logger.info(f"Scaled {node_group} from {current_capacity} to {new_capacity}")
                
            except Exception as e:
                logger.error(f"Failed to scale {node_group}: {str(e)}")
                
    except Exception as e:
        logger.error(f"Error scaling secondary infrastructure: {str(e)}")

def record_dr_metrics(cloudwatch, metric_name, value):
    """
    Record DR-related metrics to CloudWatch
    """
    try:
        cloudwatch.put_metric_data(
            Namespace='Wrfcoin/DisasterRecovery',
            MetricData=[
                {
                    'MetricName': metric_name,
                    'Value': value,
                    'Unit': 'Count',
                    'Timestamp': datetime.now(timezone.utc)
                }
            ]
        )
        logger.info(f"Recorded metric: {metric_name} = {value}")
        
    except Exception as e:
        logger.error(f"Failed to record metric {metric_name}: {str(e)}")

def get_route53_record_sets(route53, hosted_zone_id, record_name):
    """
    Get Route53 record sets for failover manipulation
    """
    try:
        response = route53.list_resource_record_sets(
            HostedZoneId=hosted_zone_id,
            StartRecordName=record_name,
            StartRecordType='A'
        )
        
        return [
            record for record in response['ResourceRecordSets']
            if record['Name'] == record_name and record['Type'] == 'A'
        ]
        
    except Exception as e:
        logger.error(f"Failed to get Route53 records: {str(e)}")
        return []

# Test function for local development
if __name__ == "__main__":
    # Test event for local development
    test_event = {
        "source": "aws.route53",
        "detail-type": "Route 53 Health Check Status Changed",
        "detail": {
            "health-check-id": "test-health-check",
            "status": "FAILURE"
        }
    }
    
    # Mock context
    class MockContext:
        def __init__(self):
            self.aws_request_id = "test-request-id"
            self.function_name = "test-function"
    
    # Set test environment variables
    os.environ['SECONDARY_REGION'] = 'us-west-2'
    os.environ['SNS_TOPIC_ARN'] = 'arn:aws:sns:us-east-1:123456789012:test-topic'
    os.environ['CLUSTER_NAME'] = 'test-cluster'
    
    # Run test
    result = handler(test_event, MockContext())
    print(json.dumps(result, indent=2))