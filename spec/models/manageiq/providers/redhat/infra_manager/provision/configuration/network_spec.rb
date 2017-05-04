require "ovirt"

describe ManageIQ::Providers::Redhat::InfraManager::Provision::Configuration::Network do
  let(:mac_address)   { "mac_address" }
  let(:network_id)    { "network1-id" }
  let(:network_name)  { "network1-name" }
  let(:rhevm_cluster) { double("Ovirt::Cluster", :find_network_by_name => {:id => network_id}) }
  let(:rhevm_nic1)    { {:id => "nic1-id", :name => "nic1", :network => {:id => network_id}, :mac => {:address => mac_address}} }
  let(:rhevm_nic2)    { {:id => "nic2-id", :name => "nic2", :network => {:id => "network2-id"}} }
  let(:ems)           { FactoryGirl.create(:ems_redhat_with_authentication) }
  let(:ems_cluster)   { FactoryGirl.create(:ems_cluster, :ext_management_system => ems) }
  let(:template)      { FactoryGirl.create(:template_redhat, :ext_management_system => ems) }
  let(:rhevm_vm)      { double("Ovirt::Vm") } # FactoryGirl.create(:vm_redhat, :ext_management_system => ems) }
  let(:target_vm)     { FactoryGirl.create(:vm_redhat, :ext_management_system => ems) }
  let(:ovirt_service) { double("Ovirt::Service", :api_path => "/api") }

  before do
    @task = FactoryGirl.create(:miq_provision_redhat,
                               :source      => template,
                               :destination => target_vm,
                               :state       => 'pending',
                               :status      => 'Ok',
                               :options     => {:src_vm_id => template.id})
    allow(@task).to receive_messages(
      :dest_cluster             => ems_cluster,
      :get_provider_destination => rhevm_vm,
      :source                   => template,
    )

    allow(Ovirt::Service).to receive_messages(:new => ovirt_service)

    allow(rhevm_vm).to receive_messages(:nics => [rhevm_nic1, rhevm_nic2], :ext_management_system => ems)
    allow(template).to receive_messages(:ext_management_system => ems)
    allow(Ovirt::Cluster).to receive_messages(:find_by_href => rhevm_cluster)
    allow_any_instance_of(ManageIQ::Providers::Redhat::InfraManager).to receive(:supported_api_versions)
                                                                            .and_return([3])
    allow(target_vm).to receive(:provider_object).and_return(rhevm_vm)
  end

  context "#configure_network_adapters" do
    context "ems version 3" do
      let(:set_vlan) { @task.options[:vlan] = [network_name, network_name] }
      before do
        allow(ems).to receive_messages(:supports_update_vnic_profile? => false)
        allow(ems.ovirt_services).to receive(:get_vm_proxy).and_return(rhevm_vm)
      end
      context "add second NIC in automate" do
        before do
          @task.options[:networks] = [nil, {:network => network_name}]
        end

        it "first NIC from dialog" do
          set_vlan
          expect(rhevm_nic1).to receive(:apply_options!)
          expect(rhevm_nic2).to receive(:apply_options!)

          @task.configure_network_adapters

          expect(@task.options[:networks]).to eq([
                                                     {:network => network_name, :mac_address => nil},
                                                     {:network => network_name}
                                                 ])
        end

        it "no NIC from dialog" do
          expect(rhevm_nic1).to receive(:destroy)
          expect(rhevm_nic2).to receive(:apply_options!)

          @task.configure_network_adapters
        end
      end

      it "dialog NIC only" do
        set_vlan

        expect(rhevm_nic1).to receive(:apply_options!)
        expect(rhevm_nic2).to receive(:destroy)

        @task.configure_network_adapters
      end

      it "no NICs" do
        @task.configure_network_adapters
      end

      context "update NICs" do
        it "should update an existing adapter's network" do
          @task.options[:networks] = [{:network => network_name}]

          expect(rhevm_vm).to receive(:nics).and_return([rhevm_nic1])
          expect(rhevm_nic1).to receive(:apply_options!).with(:name => "nic1", :network_id => network_id)

          @task.configure_network_adapters
        end

        it "should update an existing adapter's MAC address" do
          @task.options[:networks] = [{:mac_address => mac_address}]

          expect(rhevm_vm).to receive(:nics).and_return([rhevm_nic1])
          expect(rhevm_nic1).to receive(:apply_options!).with(
              :name => "nic1",
              :network_id => network_id,
              :mac_address => mac_address
          )

          @task.configure_network_adapters
        end
      end

      it "should create a new adapter with an optional MAC address" do
        @task.options[:networks] = [{:network => network_name, :mac_address => mac_address}]

        expect(rhevm_vm).to receive(:nics).and_return([])
        expect(rhevm_vm).to receive(:create_nic).with(
            :name => 'nic1',
            :network_id => network_id,
            :mac_address => mac_address
        )

        @task.configure_network_adapters
      end
    end
    context "ems version 4" do
      let(:vm_service) { double("vm_service", :nics_service => nics_service) }
      let(:vms_service) { double("vms_service", :vm_service => vm_service) }
      let(:nic1_service) { "nic1_service" }
      let(:nic2_service) { "nic2_service" }
      let(:nics_service) { "nics_service" }
      let(:vm_proxy) { "vm_proxy" }
      let(:system_service) { double("system_service", :vms_service => vms_service) }
      let(:connection) { double("connection", :system_service => system_service) }
      let(:vnic_profile_id) { "vnic_profile_id" }
      let(:set_vnic_profile) { @task.options[:vlan] = [vnic_profile_id, "vnic_profile_name" + " (" + network_name + ")"] }

      before do
        allow_any_instance_of(ManageIQ::Providers::Redhat::InfraManager).to receive(:supported_api_versions)
                                                                                .and_return([3, 4])
        allow(ems).to receive(:highest_allowed_api_version).and_return(4)
        allow(ems).to receive_messages(:supports_update_vnic_profile? => true)
        allow(ems.ovirt_services).to receive(:get_vm_proxy).and_return(rhevm_vm)
        allow(ems).to receive(:with_provider_connection).with(:version => 4).and_yield(connection)
        allow(nics_service).to receive(:nic_service)
                                   .with(rhevm_nic1[:id]) { nic1_service }
        allow(nics_service).to receive(:nic_service)
                                   .with(rhevm_nic2[:id]) { nic2_service }
        allow(vm_service).to receive(:get).and_return(vm_proxy)
        allow(vm_proxy).to receive(:nics)
        allow(connection).to receive(:follow_link).with(vm_proxy.nics) { rhevm_vm.nics }
        allow(rhevm_nic1).to receive(:name)
        allow(rhevm_nic2).to receive(:name)
      end
      context "add second NIC in automate" do
        before do
          @task.options[:networks] = [nil, {:network => vnic_profile_id}]
        end

        it "first NIC from dialog" do
          set_vnic_profile


          expect(nic1_service).to receive(:update)
          expect(nic2_service).to receive(:update)

          @task.configure_network_adapters

          expect(@task.options[:networks]).to eq([
                                                     {:network => vnic_profile_id, :mac_address => nil},
                                                     {:network => vnic_profile_id}
                                                 ])
        end

        it "no NIC from dialog" do
          expect(nic1_service).to receive(:remove)
          expect(nic2_service).to receive(:update)

          @task.configure_network_adapters
        end
      end

      it "dialog NIC only" do
        set_vnic_profile

        expect(nic1_service).to receive(:update)
        expect(nic2_service).to receive(:remove)

        @task.configure_network_adapters
      end

      it "no NICs" do
        @task.configure_network_adapters
      end

      context "update NICs" do
        it "should update an existing adapter's network" do
          @task.options[:networks] = [{:network => vnic_profile_id}]

          expect(rhevm_vm).to receive(:nics).and_return([rhevm_nic1])
          expect(nic1_service).to receive(:update).with(:name => "nic1", :vnic_profile => {:id => vnic_profile_id})

          @task.configure_network_adapters
        end

        it "should update an existing adapter's network with 'Empty' profile" do
          @task.options[:networks] = [{:network => '<Empty>'}]

          expect(rhevm_vm).to receive(:nics).and_return([rhevm_nic1])
          expect(nic1_service).to receive(:update).with(:name => "nic1", :vnic_profile => {:id => nil})

          @task.configure_network_adapters
        end

        it "should update an existing adapter's MAC address" do
          @task.options[:networks] = [{:network => vnic_profile_id, :mac_address => mac_address}]

          expect(rhevm_vm).to receive(:nics).and_return([rhevm_nic1])
          expect(nic1_service).to receive(:update).with(
              :name => "nic1",
              :vnic_profile => {:id => vnic_profile_id},
              :mac_address => mac_address
          )

          @task.configure_network_adapters
        end
      end

      it "should create a new adapter with an optional MAC address" do
        @task.options[:networks] = [{:network => vnic_profile_id, :mac_address => mac_address}]

        expect(rhevm_vm).to receive(:nics).and_return([])
        expect(nics_service).to receive(:add)
        expect(OvirtSDK4::Nic).to receive(:new).with(
            :name => 'nic1',
            :vnic_profile => {:id => "vnic_profile_id"},
            :mac_address => mac_address
        )

        @task.configure_network_adapters
      end
    end
  end

  context "#get_mac_address_of_nic_on_requested_vlan" do
    it "NIC found" do
      expect(@task.get_mac_address_of_nic_on_requested_vlan).to eq(mac_address)
    end

    it "NIC not found" do
      rhevm_nic1[:network][:id] = "network2-id"

      expect(@task.get_mac_address_of_nic_on_requested_vlan).to eq(nil)
    end
  end
end
