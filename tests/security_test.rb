control "internal-security-1.0" do
  impact 1.0
  title "Tester for Openstack security rules."
  desc "put description here"

  username = 'codysseus'

  describe sshd_config do
    its('PermitRootLogin') { should eq 'no' }
    its('PasswordAuthentication') { should eq 'no' }
  end

  # The brackets are needed because inspec is running the command, 
  # so it shows up in addition to the ssd daemon
  describe command('pgrep -f "[s]shd -D" | wc -w') do
    its('stdout') { should match (/[1]/) }
  end

  describe port(22) do
    it { should be_listening }
    its('processes') { should include 'sshd' }
  end

  describe command(
    'egrep "root|wheel|sudo" /etc/group | grep ' + username +
    ' || grep -r "' + username + '\s*ALL=(ALL)" /etc/sudoers*'
  ) do
    its('stdout') { should match (username) }
  end

  [
    'PermitRootLogin',
    'PasswordAuthentication'
  ].each do |setting|
    describe command('sudo sshd -T | egrep -i '+setting) do
      its('stdout') { should match( /#{setting} no/ ) }
    end
  end
end
