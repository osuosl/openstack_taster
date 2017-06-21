# frozen_string_literal: true

require 'fileutils'
require 'date'
require 'excon'
require 'net/ssh'
require 'pry'
require 'inspec'

class OpenStackTaster
  INSTANCE_FLAVOR_NAME = 'm1.small'
  INSTANCE_NETWORK_NAME = 'public'
  INSTANCE_NAME_PREFIX = 'taster'
  INSTANCE_VOLUME_MOUNT_POINT = '/mnt/taster_volume'

  VOLUME_TEST_FILE_NAME = 'info'
  VOLUME_TEST_FILE_CONTENTS = nil # Contents would be something like 'test-vol-1 on openpower8.osuosl.bak'
  TIMEOUT_INSTANCE_CREATE = 20
  TIMEOUT_VOLUME_ATTACH = 10
  TIMEOUT_VOLUME_PERSIST = 20
  TIMEOUT_INSTANCE_TO_BE_CREATED = 20
  TIMEOUT_INSTANCE_STARTUP = 30
  TIMEOUT_SSH_RETRY = 15

  TIME_SLUG_FORMAT = '%Y%m%d_%H%M%S'

  def initialize(
    compute_service,
    volume_service,
    image_service,
    network_service,
    ssh_keys,
    log_dir
  )
    @compute_service = compute_service
    @volume_service  = volume_service
    @image_service   = image_service
    @network_service = network_service

    @volumes = @volume_service.volumes

    @ssh_keypair     = ssh_keys[:keypair]
    @ssh_private_key = ssh_keys[:private_key]
    @ssh_public_key  = ssh_keys[:public_key] # REVIEW

    @session_id      = object_id
    @log_dir         = log_dir + "/#{@session_id}"

    @instance_flavor = @compute_service.flavors
      .select { |flavor|  flavor.name  == INSTANCE_FLAVOR_NAME  }.first
    @instance_network = @network_service.networks
      .select { |network| network.name == INSTANCE_NETWORK_NAME }.first
  end

  def taste(image_name, settings)
    image  = @compute_service.images # FIXME: Images over compute service is deprecated
      .select { |i| i.name == image_name }.first

    if image.nil?
      abort("#{image_name} is not an available image.")
    end

    distro_user_name = image.name.downcase.gsub(/[^a-z].*$/, '') # truncate downcased name at first non-alpha char
    distro_arch = image.name.downcase.slice(-2, 2)
    instance_name = format(
      '%s-%s-%s-%s',
      INSTANCE_NAME_PREFIX,
      Time.new.strftime(TIME_SLUG_FORMAT),
      distro_user_name,
      distro_arch
    )

    FileUtils.mkdir_p(@log_dir) unless Dir.exist?(@log_dir)

    instance_logger = Logger.new("#{@log_dir}/#{instance_name}.log")
  
    error_log(
      instance_logger,
      'info',
      "Tasting #{image.name} as '#{instance_name}' with username '#{distro_user_name}'.\nBuilding...",
      true
    )

    instance = @compute_service.servers.create(
      name: instance_name,
      flavor_ref: @instance_flavor.id,
      image_ref: image.id,
      nics: [{ net_id: @instance_network.id }],
      key_name: @ssh_keypair
    )

    if instance.nil?
      error_log(instance_logger, 'error', 'Failed to create instance.', true)
      return false
    end

    instance.instance_variable_set('@logger', instance_logger)

    def instance.logger
      @logger
    end

    instance.wait_for(TIMEOUT_INSTANCE_TO_BE_CREATED) { ready? }

    error_log(instance.logger, 'info', "Sleeping #{TIMEOUT_INSTANCE_STARTUP} seconds for OS startup...", true)
    sleep TIMEOUT_INSTANCE_STARTUP

    error_log(instance.logger, 'info', "Testing for instance '#{instance.id}'.", true)

    return test(instance, distro_user_name, settings) 
  end

  def test(instance, distro_user_name, settings)
    return_values = []
    return_values.push test_security(instance, distro_user_name) if settings[:security]
    return_values.push test_volumes(instance, distro_user_name) if settings[:volumes]
    return return_values.include? false
  rescue Fog::Errors::TimeoutError
    puts 'Instance creation timed out.'
    error_log(instance.logger, 'error', "Instance fault: #{instance.fault}")
    return false
  rescue Interrupt
    puts "\nCaught interrupt"
    puts "Exiting session #{@session_id}"
    raise
  ensure
    if instance
      puts "Destroying instance for session #{@session_id}.\n\n"
      instance.destroy
    end
    return false
  end

  def test_security(instance, username)
    opts = {
          "backend" => "ssh",
          "host" => instance.addresses["public"].first["addr"],
          "port" => 22,
          "user" => username,
          "keys_only" => true,
          "key_files" => @ssh_private_key,
          "logger" => instance.logger
        }

    tries = 0

    begin
      runner = Inspec::Runner.new(opts)
      runner.add_target(File.dirname(__FILE__) + '/../tests')
      runner.run
    rescue RuntimeError => e
      puts "Encountered error \"#{e.message}\" while testing the instance."
      if tries < 3
        tries += 1
        puts "Initiating SSH attempt #{tries} in #{TIMEOUT_SSH_RETRY} seconds"
        sleep TIMEOUT_SSH_RETRY
        retry
      end
      error_log(instance.logger, 'error', e.backtrace, false, 'Inspec Runner')
      error_log(instance.logger, 'error', e.message, false, 'Inspec Runner')
      return true # TODO: Don't crash when connection refused
    rescue Exception => e
      puts "Encountered error \"#{e.message}\". Aborting test."
      return true
    end

    error_log( instance.logger, 'info',
      "Inspec Test Results\n" +
      runner.report[:controls].map do |test| 
        "#{test[:status].upcase}: #{test[:code_desc]}\n#{test[:message]}"
      end.join("\n")
    )

    if runner.report[:controls].any?{|test| test[:status] == 'failed'}
      error_log(instance.logger, 'warn', 'Image failed security test suite')
      false
    end
    true
  end

  def error_log(logger, level, message, dup_stdout = false, context = nil)
    puts message if dup_stdout

    begin
      logger.add(Logger.const_get(level.upcase), message, context)
    rescue NameError
      puts
      puts "\e[31m#{level} is not a severity. Make sure that you use the correct string for logging severity!\e[0m"
      puts
      logger.error('Taster Source Code') { "#{level} is not a logging severity name. Defaulting to INFO." }
      logger.info(context) { message }
    end
  end

  def get_image_name(instance)
    @image_service
      .get_image_by_id(instance.image['id'])
      .body['name']
  end

  def create_image(instance)
    image_name = [
      instance.name,
      get_image_name(instance)
    ].join('_')

    response = instance.create_image(image_name)
    image_id = response.body['image']['id']

    @image_service.images
      .find_by_id(image_id)
      .wait_for { status == 'active' }
  end

  def test_volumes(instance, username)
    mount_failures = @volumes.reject do |volume|
      if volume.attachments.any?
        error_log(instance.logger, 'info', "Volume '#{volume.name}' is already in an attached state; skipping.", true)
        next
      end

      unless volume_attach?(instance, volume)
        error_log(instance.logger, 'error', "Volume '#{volume.name}' failed to attach. Creating image...", true)
        create_image(instance)
        return false # Returns from test_volumes
      end

      volume_mount_unmount?(instance, username, volume)
    end

    detach_failures = @volumes.reject do |volume|
      volume_detach?(instance, volume)
    end

    if mount_failures.empty? && detach_failures.empty?
      error_log(instance.logger, 'info', "\nEncountered 0 failures. Not creating image...", true)
      true
    else
      error_log(
        instance.logger,
        'error',
        "\nEncountered #{mount_failures.count} mount failures and #{detach_failures.count} detach failures.",
        true
      )
      error_log(instance.logger, 'error', "\nEncountered failures. Creating image...", true)
      create_image(instance)
      false
    end
  end

  def with_ssh(instance, username, &block)
    tries = 0
    instance.logger.progname = 'SSH'
    begin
      Net::SSH.start(
        instance.addresses['public'].first['addr'],
        username,
        verbose: :info,
        paranoid: false,
        logger: instance.logger,
        keys: [@ssh_private_key],
        &block
      )
    rescue Errno::ECONNREFUSED => e
      puts "Encountered #{e.message} while connecting to the instance."
      if tries < 3
        tries += 1
        puts "Initiating SSH attempt #{tries} in #{TIMEOUT_SSH_RETRY} seconds"
        sleep TIMEOUT_SSH_RETRY
        retry
      end
      error_log(instance.logger, 'error', e.backtrace, false, 'SSH')
      error_log(instance.logger, 'error', e.message, false, 'SSH')
      exit 1 # TODO: Don't crash when connection refused
    end
  end

  def volume_attach?(instance, volume)
    volume_attached = lambda do |_|
      volume_attachments.any? do |attachment|
        attachment['volumeId'] == volume.id
      end
    end

    error_log(instance.logger, 'info', "Attaching volume '#{volume.name}' (#{volume.id})...", true)
    @compute_service.attach_volume(volume.id, instance.id, nil)
    instance.wait_for(TIMEOUT_VOLUME_ATTACH, &volume_attached)

    error_log(instance.logger, 'info', "Sleeping #{TIMEOUT_VOLUME_PERSIST} seconds for attachment persistance...", true)
    sleep TIMEOUT_VOLUME_PERSIST

    return true if instance.instance_eval(&volume_attached)

    error_log(instance.logger, 'error', "Failed to attach '#{volume.name}': Volume was unexpectedly detached.", true)
    false
  rescue Excon::Error => e
    puts 'Error attaching volume, check log for details.'
    error_log(instance.logger, 'error', e.message)
    false
  rescue Fog::Errors::TimeoutError
    error_log(instance.logger, 'error', "Failed to attach '#{volume.name}': Operation timed out.", true)
    false
  end

  def volume_mount_unmount?(instance, username, volume)
    mount = INSTANCE_VOLUME_MOUNT_POINT
    file_name = VOLUME_TEST_FILE_NAME
    file_contents = VOLUME_TEST_FILE_CONTENTS
    vdev = @volume_service.volumes.find_by_id(volume.id)
      .attachments.first['device']
    vdev << '1'

    log_partitions(instance, username)

    commands = [
      ["echo -e \"127.0.0.1\t$HOSTNAME\" | sudo tee -a /etc/hosts", nil], # to fix problems with sudo and DNS resolution
      ['sudo partprobe -s',                        nil],
      ["[ -d '#{mount}' ] || sudo mkdir #{mount}", ''],
      ["sudo mount #{vdev} #{mount}",              ''],
      ["sudo cat #{mount}/#{file_name}",           file_contents],
      ["sudo umount #{mount}",                     '']
    ]

    error_log(instance.logger, 'info', "Mounting volume '#{volume.name}' (#{volume.id})...", true)

    error_log(instance.logger, 'info', 'Mounting from inside the instance...', true)
    with_ssh(instance, username) do |ssh|
      commands.each do |command, expected|
        result = ssh.exec!(command).chomp
        if expected.nil?
          error_log(instance.logger, 'info', "#{command} yielded '#{result}'")
        elsif result != expected
          error_log(
            instance.logger,
            'error',
            "Failure while running '#{command}':\n\texpected '#{expected}'\n\tgot '#{result}'",
            true
          )
          return false # returns from volume_mount_unmount?
        end
      end
    end
    true
  end

  def log_partitions(instance, username)
    puts 'Logging partition list and dmesg...'

    record_info_commands = [
      'cat /proc/partitions',
      'dmesg | tail -n 20'
    ]

    with_ssh(instance, username) do |ssh|
      record_info_commands.each do |command|
        result = ssh.exec!(command)
        error_log(instance.logger, 'info', "Ran '#{command}' and got '#{result}'")
      end
    end
  end

  def volume_detach?(instance, volume)
    error_log(instance.logger, 'info', "Detaching #{volume.name}.", true)
    instance.detach_volume(volume.id)
  rescue Excon::Error => e
    puts 'Failed to detach. check log for details.'
    error_log(instance.logger, 'error', e.message)
    false
  end
end
