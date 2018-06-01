# frozen_string_literal: true

require 'fileutils'
require 'date'
require 'excon'
require 'net/ssh'
require 'pry'
require 'inspec'

# @author Andrew Tolvstad, Samarendra Hedaoo, Cody Holliday
class OpenStackTaster
  INSTANCE_FLAVOR_NAME = 'm1.tiny'
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

  MAX_SSH_RETRY = 3

  TIME_SLUG_FORMAT = '%Y%m%d_%H%M%S'

  def initialize(
    compute_service,
    volume_service,
    image_service,
    network_service,
    network_name,
    ssh_keys,
    log_dir
  )
    @compute_service = compute_service
    @volume_service  = volume_service
    @image_service   = image_service
    @network_service = network_service

    @network_name = network_name || 'public'
    @volumes = @volume_service.volumes

    @ssh_keypair     = ssh_keys[:keypair]
    @ssh_private_key = ssh_keys[:private_key]
    @ssh_public_key  = ssh_keys[:public_key] # REVIEW

    @session_id      = object_id
    @log_dir         = log_dir + "/#{@session_id}"

    @instance_flavor = @compute_service.flavors
      .select { |flavor|  flavor.name  == INSTANCE_FLAVOR_NAME  }.first
    @instance_network = @network_service.networks
      .select { |network| network.name == @network_name }.first

  end

  # Taste a specified image
  # @param image_name [String] The name on OpenStack of the image to be tested.
  # @param settings [Hash] A hash of settings to enable and disable tests, snapshot creation upon failure.
  # @return [Boolean] success or failure of tests on image.
  # @note The testing section could be further streamlined by:
  #   creating a naming standard for test functions (i.e. taste_<name>)
  #   limiting the parameters of each test to be: instance, distro_username
  #   Adding a 'suites' subhash to the settings hash
  #   Then that subhash can be iterated over, use eval to call each function,
  #   appending the suite name to 'taste_' for the function name
  #   and passing the standardized parameters
  # @todo Reduce Percieved and Cyclomatic complexity
  # @todo Images over compute service is deprecated
  def taste(image_name, settings)
    image = @compute_service.images
      .select { |i| i.name == image_name }.first

    abort("#{image_name} is not an available image.") if image.nil?

    distro = image.name.downcase[/^[a-z]*/]
    instance_name = format(
      '%s-%s-%s',
      INSTANCE_NAME_PREFIX,
      Time.new.strftime(TIME_SLUG_FORMAT),
      distro
    )

    FileUtils.mkdir_p(@log_dir) unless Dir.exist?(@log_dir)

    instance_logger = Logger.new("#{@log_dir}/#{instance_name}.log")

    error_log(
      instance_logger,
      'info',
      "Tasting #{image.name} as '#{instance_name}' with username '#{settings[:ssh_user]}'.\nBuilding...",
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

    instance.class.send(:attr_accessor, 'logger')

    instance.logger = instance_logger

    instance.wait_for(TIMEOUT_INSTANCE_TO_BE_CREATED) { ready? }

    error_log(instance.logger, 'info', "Sleeping #{TIMEOUT_INSTANCE_STARTUP} seconds for OS startup...", true)
    sleep TIMEOUT_INSTANCE_STARTUP

    error_log(instance.logger, 'info', "Testing for instance '#{instance.id}'.", true)

    # Run tests
    return_values = []
    return_values.push taste_security(instance, settings[:ssh_user]) if settings[:security]
    return_values.push taste_volumes(instance, settings[:ssh_user]) if settings[:volumes]

    if settings[:create_snapshot] && !return_values.all?
      error_log(instance.logger, 'info', "Tests failed for instance '#{instance.id}'. Creating image...", true)
      create_image(instance) # Create image here since it is destroyed before scope returns to taste function
    end
    return return_values.all?
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
  end

  # Runs the security test suite using inspec
  # @param instance [Fog::Image::OpenStack::Image] The instance to test.
  # @param username [String] The username to use when logging into the instance.
  # @return [Boolean] Whether or not the image passed hte security tests.
  # @todo Don't crash when connection refused.
  def taste_security(instance, username)
    opts = {
      'backend' => 'ssh',
      'host' => instance.addresses[@network_name].first['addr'],
      'port' => 22,
      'user' => username,
      'sudo' => true,
      'keys_only' => true,
      'key_files' => @ssh_private_key,
      'logger' => instance.logger
    }

    tries = 0

    begin
      runner = Inspec::Runner.new(opts)
      runner.add_target(File.dirname(__FILE__) + '/../tests')
      runner.run
    rescue RuntimeError => e
      puts "Encountered error \"#{e.message}\" while testing the instance."
      if tries < MAX_SSH_RETRY
        tries += 1
        puts "Initiating SSH attempt #{tries} in #{TIMEOUT_SSH_RETRY} seconds"
        sleep TIMEOUT_SSH_RETRY
        retry
      end
      error_log(instance.logger, 'error', e.backtrace, false, 'Inspec Runner')
      error_log(instance.logger, 'error', e.message, false, 'Inspec Runner')
      return true
    rescue StandardError => e
      puts "Encountered error \"#{e.message}\". Aborting test."
      return true
    end

    error_log(
      instance.logger,
      'info',
      "Inspec Test Results\n" +
      runner.report[:controls].map do |test|
        "#{test[:status].upcase}: #{test[:code_desc]}\n#{test[:message]}"
      end.join("\n")
    )

    if runner.report[:controls].any? { |test| test[:status] == 'failed' }
      error_log(instance.logger, 'warn', 'Image failed security test suite')
      return false
    end
    true
  end

  # Write an error message to the log and optionally stdout.
  # @param logger [Logger] the logger used to record the message.
  # @param level [String] the level to use when logging.
  # @param message [String] the message to write
  # @param dup_stdout [Boolean] whether or not to print the message to stdout
  # @param context [String] the context of the message to be logged. i.e. SSH, Inspec, etc.
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

  # Get the name of the image from which an instance was created.
  # @param instance [Fog::Compute::OpenStack::Server] the instance to query
  # @return [String] the name of the image
  def get_image_name(instance)
    @image_service
      .get_image_by_id(instance.image['id'])
      .body['name']
  end

  # Create an image of an instance.
  # @note This method blocks until snapshot creation is complete on the server.
  # @param instance [Fog::Compute::OpenStack::Server] the instance to query
  # @return [Fog::Image::OpenStack::Image] the generated image
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

  # Run the set of tests for each available volume on an instance.
  # @param instance [Fog::Compute::OpenStack::Server] the instance to query
  # @param username [String] the username to use when logging into the instance
  # @return [Boolean] Whether or not the tests succeeded
  def taste_volumes(instance, username)
    mount_failures = @volumes.reject do |volume|
      if volume.attachments.any?
        error_log(instance.logger, 'info', "Volume '#{volume.name}' is already in an attached state; skipping.", true)
        next
      end

      unless volume_attach?(instance, volume)
        error_log(instance.logger, 'error', "Volume '#{volume.name}' failed to attach.", true)
        next
      end

      volume_mount_unmount?(instance, username, volume)
    end

    detach_failures = @volumes.reject do |volume|
      volume_detach?(instance, volume)
    end

    if mount_failures.empty? && detach_failures.empty?
      error_log(instance.logger, 'info', "\nEncountered 0 failures.", true)
      true
    else
      error_log(
        instance.logger,
        'error',
        "\nEncountered #{mount_failures.count} mount failures and #{detach_failures.count} detach failures.",
        true
      )
      error_log(instance.logger, 'error', "\nEncountered failures.", true)
      false
    end
  end

  # A helper method to execute a series of commands remotely on an instance. This helper
  # passes its block directly to `Net::SSH#start()`.
  # @param instance [Fog::Compute::OpenStack::Server] the instance on which to run the commands
  # @param username [String] the username to use when logging into the instance
  # @todo Don't crash when connection refused.
  def with_ssh(instance, username, &block)
    tries = 0
    instance.logger.progname = 'SSH'
    begin
      Net::SSH.start(
        instance.addresses[@network_name].first['addr'],
        username,
        verbose: :info,
        paranoid: false,
        logger: instance.logger,
        keys: [@ssh_private_key],
        &block
      )
    rescue Errno::ECONNREFUSED => e
      puts "Encountered #{e.message} while connecting to the instance."
      if tries < MAX_SSH_RETRY
        tries += 1
        puts "Initiating SSH attempt #{tries} in #{TIMEOUT_SSH_RETRY} seconds"
        sleep TIMEOUT_SSH_RETRY
        retry
      end
      error_log(instance.logger, 'error', e.backtrace, false, 'SSH')
      error_log(instance.logger, 'error', e.message, false, 'SSH')
      exit 1
    end
  end

  # Test volume attachment for a given instance and volume.
  # @param instance [Fog::Compute::OpenStack::Server] the instance to which to attach the volume
  # @param volume [Fog::Volume::OpenStack::Volume] the volume to attach
  # @return [Boolean] whether or not the attachment was successful
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

    # In the off chance that the volume host goes down, catch it.
    if instance.instance_eval(&volume_attached)
      return true if volume.reload.attachments.first
      error_log(instance.logger, 'error', "Failed to attach '#{volume.name}': Volume host might be down.", true)
    else
      error_log(instance.logger, 'error', "Failed to attach '#{volume.name}': Volume was unexpectedly detached.", true)
    end

    false
  rescue Excon::Error => e
    puts 'Error attaching volume, check log for details.'
    error_log(instance.logger, 'error', e.message)
    false
  rescue Fog::Errors::TimeoutError
    error_log(instance.logger, 'error', "Failed to attach '#{volume.name}': Operation timed out.", true)
    false
  end

  # Test volume mounting and unmounting for an instance and a volume.
  # @param instance [Fog::Compute::OpenStack::Server] the instance on which to mount the volume
  # @param username [String] the username to use when logging into the instance
  # @param volume [Fog::Volume::OpenStack::Volume] the volume to mount
  # @return [Boolean] whether or not the mounting/unmounting was successful
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

  # Log instance's partition listing.
  # @param instance [Fog::Compute::OpenStack::Server] the instance to log
  # @param username [String] the username to use when logging in to the instance
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

  # Detach volume from instance.
  # @param instance [Fog::Compute::OpenStack::Server] the instance from which to detach
  # @param volume [Fog::Volume::OpenStack::Volume] the volume to detach
  # @return [Boolean] whether or not the detachment succeeded
  def volume_detach?(instance, volume)
    error_log(instance.logger, 'info', "Detaching #{volume.name}.", true)
    instance.detach_volume(volume.id)
  rescue Excon::Error => e
    puts 'Failed to detach. check log for details.'
    error_log(instance.logger, 'error', e.message)
    false
  end
end
