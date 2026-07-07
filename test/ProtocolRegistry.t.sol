// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ProtocolRegistry} from "../src/ProtocolRegistry.sol";
import {AdapterType, PositionClass, Status, ProtocolPosition} from "../src/Types.sol";

contract ProtocolRegistryTest is Test {
    ProtocolRegistry reg;

    address admin = makeAddr("admin");
    address stranger = makeAddr("stranger");
    address target = makeAddr("target");
    address asset = makeAddr("asset");

    function setUp() public {
        reg = new ProtocolRegistry(admin);
    }

    function test_addProtocol_activeAndId() public {
        vm.prank(admin);
        bytes32 id = reg.addProtocol(AdapterType.AAVE, target, asset, "lending");

        assertEq(id, reg.positionId(AdapterType.AAVE, target, asset));
        ProtocolPosition memory p = reg.getProtocol(id);
        assertEq(uint8(p.adapterType), uint8(AdapterType.AAVE));
        assertEq(p.target, target);
        assertEq(p.asset, asset);
        assertEq(p.category, bytes32("lending"));
        assertEq(uint8(p.status), uint8(Status.ACTIVE));
    }

    function test_addProtocol_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reg.addProtocol(AdapterType.AAVE, target, asset, "lending");
    }

    function test_addProtocol_badAdapter() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolRegistry.BadAdapter.selector);
        reg.addProtocol(AdapterType.NONE, target, asset, "x");
    }

    function test_addProtocol_zero() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolRegistry.ZeroAddress.selector);
        reg.addProtocol(AdapterType.AAVE, address(0), asset, "x");
    }

    function test_disable_keepsRecord() public {
        vm.startPrank(admin);
        bytes32 id = reg.addProtocol(AdapterType.AAVE, target, asset, "lending");
        reg.disableProtocol(id);
        vm.stopPrank();

        ProtocolPosition memory p = reg.getProtocol(id);
        assertEq(uint8(p.status), uint8(Status.DISABLED));
        assertEq(p.target, target); // record kept -> exit still resolves
    }

    function test_disable_unknown() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolRegistry.UnknownPosition.selector);
        reg.disableProtocol(bytes32("nope"));
    }

    function test_assetLifecycle() public {
        vm.startPrank(admin);
        reg.addAsset(asset, PositionClass.STABLECOIN);
        assertTrue(reg.isAssetApproved(asset));
        reg.disableAsset(asset);
        assertFalse(reg.isAssetApproved(asset));
        vm.stopPrank();
    }

    function test_addAsset_badClass() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolRegistry.BadClass.selector);
        reg.addAsset(asset, PositionClass.PROTOCOL);
    }

    function test_setRoute() public {
        address router = makeAddr("router");
        vm.startPrank(admin);
        reg.setRoute(router, true);
        assertTrue(reg.routeApproved(router));
        reg.setRoute(router, false);
        assertFalse(reg.routeApproved(router));
        vm.stopPrank();
    }

    function test_ownershipTwoStep() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        reg.transferOwnership(newAdmin);
        assertEq(reg.owner(), admin); // not transferred yet
        assertEq(reg.pendingOwner(), newAdmin);

        vm.prank(newAdmin);
        reg.acceptOwnership();
        assertEq(reg.owner(), newAdmin);
    }
}
