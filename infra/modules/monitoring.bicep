// Log Analytics and the alerts worth having on day one.
//
// Container Apps sends console and system logs here automatically once the
// environment is pointed at this workspace, which is what makes the logs of a
// job execution readable after the container that wrote them is gone. That
// matters more here than usual: a run worker and an ingest job are destroyed
// the moment they finish, so this workspace is the only place their output
// survives.
//
// Two alerts, both chosen because they catch failures that are otherwise
// silent -- a Dagster run that fails loudly is already visible in the UI and
// does not need an alert to say so.

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Days to retain logs. 30 is the free floor; longer costs money.')
param retentionInDays int = 30

@description('Email address for alert notifications. Leave empty to create the alerts without a notification target.')
param alertEmail string = ''

@description('Create the alert rules. The workspace is always created; the environment needs it.')
param deployAlerts bool = true

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

var hasEmail = !empty(alertEmail)

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (deployAlerts && hasEmail) {
  name: 'ag-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(replace(namePrefix, '-', ''), 12)
    enabled: true
    emailReceivers: [
      {
        name: 'primary'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

var actionGroups = (deployAlerts && hasEmail) ? [{ actionGroupId: actionGroup.id }] : []

// ---------------------------------------------------------------------------
// Alert 1: a job execution that ended badly.
//
// The Dagster daemon's run monitoring already marks a run failed when its
// worker dies, so this is not about the run record. It is about the failures
// that happen *before* Dagster is involved at all -- an image that will not
// pull, a container that exits non-zero on startup, an identity that lost a
// role assignment. Those never reach the event log, so nothing in the Dagster
// UI would ever show them.
// ---------------------------------------------------------------------------
resource jobFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (deployAlerts) {
  name: 'alert-${namePrefix}-job-failures'
  location: location
  tags: tags
  properties: {
    displayName: 'Container Apps job execution failed (${namePrefix})'
    description: 'A Dagster run worker or ingest job execution reached a failed state.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      workspace.id
    ]
    criteria: {
      allOf: [
        {
          query: 'ContainerAppSystemLogs_CL\n| where Type_s == "Warning" or Reason_s in ("Failed", "BackOff", "ExecutionFailed")\n| summarize Count = count() by ContainerAppName_s, Reason_s'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [for g in actionGroups: g.actionGroupId]
    }
  }
}

// ---------------------------------------------------------------------------
// Alert 2: the daemon is not running.
//
// This is the one that actually matters. The daemon owns schedules, sensors
// and the run queue, and when it stops, nothing fails -- runs simply stop
// being created. Without this alert the symptom is somebody noticing days
// later that yesterday's data never arrived.
// ---------------------------------------------------------------------------
resource daemonReplicaAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (deployAlerts) {
  name: 'alert-${namePrefix}-daemon-down'
  location: 'global'
  tags: tags
  properties: {
    description: 'The Dagster daemon has no running replica. Schedules and sensors are not firing.'
    severity: 1
    enabled: true
    scopes: [
      resourceId('Microsoft.App/containerApps', 'ca-${namePrefix}-daemon')
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'replicas'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'Replicas'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: [for g in actionGroups: { actionGroupId: g.actionGroupId }]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output customerId string = workspace.properties.customerId
