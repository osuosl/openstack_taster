control "internal-security-1.0" do
  impact 1.0
  title "Tester for Openstack security rules."
  desc "put description here"

  username = user.username

  describe sshd_config do
    its('PermitRootLogin') { should cmp /(no|without-password|prohibit-password)/ }
    its('PasswordAuthentication') { should eq 'no' }
  end

  describe processes('sshd') do
    its('list.length') { should eq 1 } #Our version of inspec doesn't complain, but "list" should be changed to "entries"
  end

  describe command(
    'egrep "root|wheel|sudo" /etc/group | grep ' + username +
    ' || sudo grep -r "' + username + '\s*ALL=(ALL[:ALL]*)" /etc/sudoers*'
  ) do
    its('stdout') { should match (username) }
  end

  [
    'PermitRootLogin',
    'PasswordAuthentication'
  ].each do |setting|
    describe command('sudo sshd -T | egrep -i '+setting) do
      its('stdout') { should match( /#{setting} (no|without-password|prohibit-password)/i ) }
    end
  end
end
