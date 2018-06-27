# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name        = 'openstack_taster'
  spec.version     = '1.1.0'
  spec.summary     = "Taste all of the OpenStack's basic functionality for an image"
  spec.description = 'Tastes images on an OpenStack deployment for security and basic usability.'
  spec.author      = ['OSU Open Source Lab']
  spec.email       = 'support@osuosl.org'
  spec.licenses    = ['Apache-2.0']
  spec.homepage    = 'https://github.com/osuosl/openstack_taster'
  spec.add_runtime_dependency 'inspec', '~> 1.10', '>= 1.10.0'
  spec.add_runtime_dependency 'fog-openstack', '~> 0.1.19'
  spec.add_runtime_dependency 'net-ssh', '~> 3.2', '>= 3.2.0'
  spec.add_runtime_dependency 'json', '~> 1.8', '>= 1.8.6'
  spec.executables = 'openstack_taster'
  spec.files       = [
    'lib/openstack_taster.rb',
    'bin/openstack_taster',
    'tests/inspec.yml',
    'tests/controls/security_test.rb'
  ]
end
