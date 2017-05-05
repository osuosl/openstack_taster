control "internal-security-1.0" do
  impact 1.0
  title "Tester for Openstack security rules."
  desc "put description here"
  describe sshd_config do
    its('PermitRootLogin') { should eq 'no' }
    its('PasswordAuthentication') { should eq 'no' }
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
