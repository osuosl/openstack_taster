control "external-security-1.0" do
  impact 1.0
  title "Tester for Openstack security rules."
  desc "put description here"
  describe command() do
    its('stdout') { should match () }
  end
end
