# frozen_string_literal: true
control 'security-1.0' do
  impact 1.0
  title 'Openstack Image Security Test'
  desc 'Tests the security of images used for Openstack.'

  username = os.name

  describe 'saved sshd config' do
    let(:resource) { command('sudo cat /etc/ssh/sshd_config') }

    it 'should not permit root login' do
      expect(resource.stdout).to cmp(/^PermitRootLogin no/i)
    end

    it 'should not permit password authentication' do
      expect(resource.stdout).to cmp(/^PasswordAuthentication no/i)
    end

    it 'should not permit challenge response authentication' do
      expect(resource.stdout).to cmp(/^ChallengeResponseAuthentication no/i)
    end
    it 'should not permit keyboard interactive authentication' do
      expect(resource.stdout).to cmp(/^KbdInteractiveAuthentication no/i)
    end
  end

  describe 'running sshd config' do
    let(:resource) { command('sudo sshd -T') }

    it 'should not permit root login' do
      expect(resource.stdout).to cmp(/^PermitRootLogin no/i)
    end

    it 'should not permit password authentication' do
      expect(resource.stdout).to cmp(/^PasswordAuthentication no/i)
    end

    it 'should not permit challenge response authentication' do
      expect(resource.stdout).to cmp(/^ChallengeResponseAuthentication no/i)
    end
    it 'should not permit keyboard interactive authentication' do
      expect(resource.stdout).to cmp(/^KbdInteractiveAuthentication no/i)
    end
  end

  # Our version of inspec does not give us a warning about the list matcher,
  # but in version 2.0 of inspec this will be removed.
  # This tests the number of instances of sshd on the system.
  describe processes('sshd') do
    its('list.length') { should eq 1 }
  end

  describe.one do
    describe user(username) do
      its('groups') { should eq %w(root wheel sudo) }
    end

    describe command('sudo -U ' + username + ' -l') do
      its('stdout') { should cmp(/\(ALL\) ((NO)*PASSWD)*: ALL/) }
    end
  end
end

control 'ports-1.0' do
  impact 1.0
  title 'Openstack Image Ports Test'
  desc 'Tests the open ports of images used for Openstack.'

  # Skip these tests if we detect openstack is installed
  only_if { !file('/etc/keystone').exist? }

  # ssh should be the only thing listening
  describe port.where { protocol =~ /tcp/ && port != 22 && address !~ /^127/ } do
    it { should_not be_listening }
  end

  # It's OK if dhclient is listening
  describe port.where { protocol =~ /udp/ && port != 68 && process != 'dhclient' && address !~ /^127/ } do
    it { should_not be_listening }
  end
end
