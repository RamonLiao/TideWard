#[test_only]
module riskguard::upgrade_registry_tests;

use sui::test_scenario as ts;
use sui::clock;
use sui::package::{Self, UpgradeCap};
use std::unit_test::{assert_eq, destroy};
use riskguard::caps::{Self, AdminCap};
use riskguard::upgrade_registry::{Self, UpgradeRegistry};

const DEPLOYER: address = @0xAD;   // ops multisig (holds AdminCap + UpgradeCap)
const RANDO: address    = @0xBEEF; // permissionless executor
const TIMELOCK_MS: u64  = 259_200_000; // 72h
// Dummy 32-byte bytecode digest.
const DIGEST: vector<u8> = x"1111111111111111111111111111111111111111111111111111111111111111";

// Mints an AdminCap and a test UpgradeCap to DEPLOYER, returns nothing (objects in inventory).
fun mint_caps(sc: &mut ts::Scenario) {
    let admin = caps::new_admin_cap(sc.ctx());
    transfer::public_transfer(admin, DEPLOYER);
    let pkg_id = object::id_from_address(@0xCAFE);
    let ucap = package::test_publish(pkg_id, sc.ctx());
    transfer::public_transfer(ucap, DEPLOYER);
}

#[test]
fun init_wraps_cap_and_shares_registry() {
    let mut sc = ts::begin(DEPLOYER);
    mint_caps(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let ucap = ts::take_from_sender<UpgradeCap>(&sc);
    upgrade_registry::init_upgrade_registry(ucap, &admin, sc.ctx());
    ts::return_to_sender(&sc, admin);

    sc.next_tx(DEPLOYER);
    // Registry is now a shared object with no pending proposal.
    let reg = ts::take_shared<UpgradeRegistry>(&sc);
    assert!(!upgrade_registry::has_pending(&reg));
    assert_eq!(upgrade_registry::timelock_ms(&reg), TIMELOCK_MS);
    ts::return_shared(reg);
    sc.end();
}

// --- helper: init registry and return it shared-taken in a fresh tx ---
fun setup_registry(sc: &mut ts::Scenario) {
    mint_caps(sc);
    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let ucap = ts::take_from_sender<UpgradeCap>(sc);
    upgrade_registry::init_upgrade_registry(ucap, &admin, sc.ctx());
    ts::return_to_sender(sc, admin);
}

#[test]
fun propose_sets_pending() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000);
    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);
    assert!(upgrade_registry::has_pending(&reg));

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::EUpgradePending)]
fun propose_twice_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());
    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);
    // Second proposal while one is pending must abort.
    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}

#[test]
fun cancel_clears_pending_and_allows_reproposal() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());

    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);
    assert!(upgrade_registry::has_pending(&reg));
    let epoch_before = upgrade_registry::current_epoch(&reg);

    upgrade_registry::cancel_upgrade(&mut reg, &admin, sc.ctx());
    assert!(!upgrade_registry::has_pending(&reg));
    // Epoch advanced so the indexer can't conflate this cancel with a re-proposal.
    assert_eq!(upgrade_registry::current_epoch(&reg), epoch_before + 1);

    // Re-proposing the same digest now succeeds.
    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);
    assert!(upgrade_registry::has_pending(&reg));

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::ENoPending)]
fun cancel_without_pending_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    upgrade_registry::cancel_upgrade(&mut reg, &admin, sc.ctx()); // no pending → abort

    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::ETimelockActive)]
fun execute_before_timelock_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000);
    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);
    ts::return_to_sender(&sc, admin);

    // Permissionless executor, but only 1s elapsed → abort.
    sc.next_tx(RANDO);
    clk.set_for_testing(2_000);
    let ticket = upgrade_registry::execute_upgrade(&mut reg, &clk);
    // Unreachable (execute aborts above). UpgradeReceipt lacks `drop`, so close the
    // hot-potato chain via std::unit_test::destroy to satisfy the type checker.
    destroy(package::test_upgrade(ticket));

    clk.destroy_for_testing();
    ts::return_shared(reg);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::ENoPending)]
fun execute_without_pending_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(RANDO);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());
    let ticket = upgrade_registry::execute_upgrade(&mut reg, &clk);
    // Unreachable (execute aborts above). UpgradeReceipt lacks `drop`, so close the
    // hot-potato chain via std::unit_test::destroy to satisfy the type checker.
    destroy(package::test_upgrade(ticket));

    clk.destroy_for_testing();
    ts::return_shared(reg);
    sc.end();
}

#[test]
fun full_lifecycle_bumps_version_and_clears_pending() {
    let mut sc = ts::begin(DEPLOYER);
    setup_registry(&mut sc);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_000);
    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);
    ts::return_to_sender(&sc, admin);

    // Advance past the 72h timelock; permissionless executor drives it.
    sc.next_tx(RANDO);
    clk.set_for_testing(1_000 + TIMELOCK_MS);
    let ticket = upgrade_registry::execute_upgrade(&mut reg, &clk);
    // test_upgrade stands in for the on-chain Upgrade command.
    let receipt = package::test_upgrade(ticket);
    upgrade_registry::commit_upgrade(&mut reg, receipt);

    // Pending cleared; cap version bumped 1 → 2.
    assert!(!upgrade_registry::has_pending(&reg));
    assert_eq!(upgrade_registry::cap_version(&reg), 2);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    sc.end();
}

#[test]
#[expected_failure(abort_code = upgrade_registry::EPolicyTooPermissive)]
fun propose_too_permissive_aborts() {
    let mut sc = ts::begin(DEPLOYER);
    mint_caps(&mut sc);
    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut ucap = ts::take_from_sender<UpgradeCap>(&sc);
    // Raise cap policy to ADDITIVE(128); proposing COMPATIBLE(0) is more permissive → abort.
    package::only_additive_upgrades(&mut ucap);
    upgrade_registry::init_upgrade_registry(ucap, &admin, sc.ctx());
    ts::return_to_sender(&sc, admin);

    sc.next_tx(DEPLOYER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut reg = ts::take_shared<UpgradeRegistry>(&sc);
    let clk = clock::create_for_testing(sc.ctx());
    upgrade_registry::propose_upgrade(&mut reg, &admin, DIGEST, package::compatible_policy(), &clk);

    clk.destroy_for_testing();
    ts::return_shared(reg);
    ts::return_to_sender(&sc, admin);
    sc.end();
}
