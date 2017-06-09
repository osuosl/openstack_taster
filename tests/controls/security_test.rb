control "security-1.0" do
  impact 1.0
  title "Openstack Image Security Test"
  desc "Tests the security of images used for Openstack."

  username = user.username

  describe sshd_config do
    its('PermitRootLogin') { should eq 'no' }
    its('PasswordAuthentication') { should eq 'no' }
    its('ChallengeResponseAuthentication') { should eq 'no' }
    its('KbdInteractiveAuthentication') { should eq 'no' }
  end

  describe 'running sshd config' do
    let(:resource) { command('sudo sshd -T') }

    it 'should not permit root login' do
      expect(resource.stdout).to cmp /^PermitRootLogin no/i
    end

    it 'should not permit password authentication' do
      expect(resource.stdout).to cmp /^PasswordAuthentication no/i
    end

    it 'should not permit challenge response authentication' do
      expect(resource.stdout).to cmp /^ChallengeResponseAuthentication no/i
    end
    it 'should not permit keyboard interactive authentication' do
      expect(resource.stdout).to cmp /^KbdInteractiveAuthentication no/i
    end
  end

=begin
  Our version of inspec does not give us a warning about the list matcher,
  but in version 2.0 of inspec this will be removed.
  This tests the number of instances of sshd on the system.
=end
  describe processes('sshd') do
    its('list.length') { should eq 1 } 
  end

  describe.one do
    describe user(username) do
      its('groups') { should eq %w(root wheel sudo) }
    end
  
    describe command('sudo -U ' + username + ' -l') do
      its('stdout') { should cmp /\(ALL\) (NO)*(PASSWD)*: ALL/ }
    end
  end
end
