require 'fluent/output'
require 'fluent/filter'

require 'ingress_services_pb'
require 'envelope_pb'

module Fluent
  class LoggregatorOutput < Output
    Plugin.register_output('loggregator', self)

    def load_certs(conf)
      files = [
        conf['loggregator_ca_file'],
        conf['loggregator_key_file'],
        conf['loggregator_cert_file']
      ]
      files.map { |f| File.open(f).read }
    end

    def configure(conf)
      super
      creds = GRPC::Core::ChannelCredentials.new(*load_certs(conf))
      @stub = Loggregator::V2::Ingress::Stub.new(conf['loggregator_target'], creds)
    end

    def emit(_tag, es, chain)
      chain.next
      es.each do |time, record|
        batch = Loggregator::V2::EnvelopeBatch.new
        env = Loggregator::V2::Envelope.new
        log = Loggregator::V2::Log.new

        log.payload = record['log']
        log.type = :ERR if record['stream'] == 'stderr'

        env.log = log
        env.timestamp = (time.to_f * (10**9)).to_i
        env.source_id = record.fetch('kubernetes', {}).fetch('owner', '')
        env.instance_id = record.fetch('kubernetes', {}).fetch('pod_id', '')
        env.tags['pod_name'] = record.fetch('kubernetes', {}).fetch('pod_name', '')
        env.tags['namespace'] = record.fetch('kubernetes', {}).fetch('namespace_name', '')
        env.tags['container'] = record.fetch('kubernetes', {}).fetch('container_name', '')
        env.tags['cluster'] = record.fetch('kubernetes', {}).fetch('host', '')
        batch.batch << env

        begin
          retries ||= 0
          @stub.send(batch)
        rescue GRPC::Unavailable => e
          if (retries += 1) < 3
            sleep 2
            retry
          else
            raise e
          end
        end
      end
    end
  end

  class SourceIDFilter < Filter
    Plugin.register_filter('source_id', self)

    def configure(_conf)
      @client = KubernetesClient.new
      @cache = {}
    end

    def filter(_tag, _time, record)
      k8s = record.fetch('kubernetes')
      return record unless k8s

      owner = cached_owner(
        k8s.fetch('namespace_name', ''),
        'Pod',
        k8s.fetch('pod_name', '')
      )
      k8s['owner'] = owner

      record
    end

    def cached_owner(namespace_name, resource_type, resource_name)
      cache_key = source_id(namespace_name, resource_type, resource_name)
      cache_result = @cache[cache_key]
      return cache_result unless cache_result.nil?

      result = resolve_owner(namespace_name, resource_type, resource_name)
      @cache[cache_key] = result
      result
    end

    def resolve_owner(namespace_name, resource_type, resource_name)
      input_source_id = source_id(
        namespace_name,
        resource_type,
        resource_name
      )

      obj = case resource_type
            when 'Pod'
              @client.get_pod(resource_name, namespace_name)
            when 'ReplicationController'
              @client.get_replicationcontroller(resource_name, namespace_name)
            when 'ReplicaSet'
              @client.get_replicaset(resource_name, namespace_name)
            when 'Deployment'
              @client.get_deployment(resource_name, namespace_name)
            when 'DaemonSet'
              @client.get_daemonset(resource_name, namespace_name)
            when 'StatefulSet'
              @client.get_statefulset(resource_name, namespace_name)
            when 'Job'
              @client.get_job(resource_name, namespace_name)
            when 'CronJob'
              @client.get_cronjob(resource_name, namespace_name)
      end

      return input_source_id if obj.nil?

      if (resource_type == 'StatefulSet') && (get_annotations_app_name(obj) != '')
        return source_id(
          namespace_name,
          resource_type,
          get_annotations_app_name(obj)
        )
      end

      ownerReferences = obj.fetch('metadata', {}).fetch('ownerReferences', [])
      return input_source_id if ownerReferences.empty?

      resolve_owner(
        namespace_name,
        ownerReferences[0]['kind'],
        ownerReferences[0]['name']
      )
    end

    def get_annotations_app_name(obj)
      obj.fetch('metadata', {}).fetch('annotations', {}).fetch('application_name', '')
    end

    def source_id(namespace_name, resource_type, resource_name)
      format('%s/%s/%s', namespace_name, resource_type.downcase, resource_name)
    end
  end
end

require 'net/http'
require 'net/https'
require 'uri'
require 'json'

class KubernetesClient
  def initialize(token: nil)
    @url = 'https://kubernetes.default.svc.cluster.local'
    ca_file = '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
    if token
      @token = token
    else
      token_file = '/var/run/secrets/kubernetes.io/serviceaccount/token'
      @token = File.read(token_file)
    end

    uri = URI.parse(@url)
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.use_ssl = true
    @http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    @http.ca_file = ca_file
  end

  private

  def method_missing(method_name, resource_name, namespace_name)
    name = method_name.to_s.sub('get_', '')
    request = make_request(namespace_name, name.to_sym, resource_name)
    response = @http.request(request)
    JSON.parse(response.body)
  end

  def resource_url(namespace_name, resource_type, resource_name)
    format({
      pod: '%s/api/v1/namespaces/%s/pods/%s',
      replicationcontroller: '%s/api/v1/namespaces/%s/replicationcontrollers/%s',
      replicaset: '%s/apis/apps/v1/namespaces/%s/replicasets/%s',
      deployment: '%s/apis/apps/v1/namespaces/%s/deployments/%s',
      daemonset: '%s/apis/apps/v1/namespaces/%s/daemonsets/%s',
      statefulset: '%s/apis/apps/v1/namespaces/%s/statefulsets/%s',
      job: '%s/apis/batch/v1/namespaces/%s/jobs/%s',
      cronjob: '%s/apis/batch/v1beta1/namespaces/%s/cronjobs/%s'
    }[resource_type], @url, namespace_name, resource_name)
  end

  def make_request(namespace_name, resource_type, resource_name)
    uri = URI.parse(resource_url(namespace_name, resource_type, resource_name))
    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = 'Bearer ' + @token
    request
  end
end
