import 'package:bungie_api/enums/destiny_class_enum.dart';
import 'package:bungie_api/enums/tier_type_enum.dart';
import 'package:bungie_api/models/destiny_character_component.dart';
import 'package:bungie_api/models/destiny_equip_item_result.dart';
import 'package:bungie_api/models/destiny_inventory_bucket_definition.dart';
import 'package:bungie_api/models/destiny_inventory_item_definition.dart';
import 'package:bungie_api/models/destiny_item_component.dart';
import 'package:bungie_api/models/destiny_item_instance_component.dart';
import 'package:bungie_api/enums/bucket_scope_enum.dart';
import 'package:little_light/services/bungie_api/bungie_api.service.dart';
import 'package:little_light/services/bungie_api/enums/inventory_bucket_hash.enum.dart';
import 'package:little_light/services/bungie_api/enums/item_type.enum.dart';
import 'package:little_light/services/littlelight/models/loadout.model.dart';
import 'package:little_light/services/manifest/manifest.service.dart';
import 'package:little_light/services/profile/profile.service.dart';
import 'package:bungie_api/enums/bucket_category_enum.dart';

enum ItemDestination { Character, Inventory, Vault }
enum TransferErrorCode {
  cantFindSubstitute,
  cantPullFromPostmaster,
  cantMoveToVault,
  cantMoveToCharacter,
  cantEquip,
  cantUnequip
}

class TransferError {
  final TransferErrorCode code;

  TransferError(this.code);
}

class InventoryService {
  final api = BungieApiService();
  final profile = ProfileService();
  final manifest = ManifestService();

  transfer(DestinyItemComponent item, String sourceCharacterId,
      ItemDestination destination,
      [String destinationCharacterId]) async {
    await _transfer(
        item, sourceCharacterId, destination, destinationCharacterId);
  }

  equip(DestinyItemComponent item, String sourceCharacterId,
      String destinationCharacterId) async {
    await _equip(item, destinationCharacterId);
  }

  unequip(DestinyItemComponent item, String characterId) async {
    await _unequip(item, characterId);
  }

  transferLoadout(Loadout loadout,
      [String characterId, bool andEquip = false]) async {
    List<String> equippedIds =
        loadout.equipped.map((item) => item.itemInstanceId).toList();
    List<String> unequippedIds =
        loadout.unequipped.map((item) => item.itemInstanceId).toList();
    List<DestinyItemComponent> items =
        profile.getItemsByInstanceId(equippedIds + unequippedIds);
    List<int> hashes = items.map((item) => item.itemHash).toList();
    Map<int, DestinyInventoryItemDefinition> defs =
        await manifest.getDefinitions<DestinyInventoryItemDefinition>(hashes);
    DestinyCharacterComponent character =
        characterId != null ? profile.getCharacter(characterId) : null;

    List<DestinyItemComponent> itemsToEquip = items.where((item) {
      DestinyInventoryItemDefinition def = defs[item.itemHash];
      if (!equippedIds.contains(item.itemInstanceId)) return false;
      if (character != null &&
          def.classType != character.classType &&
          def.classType != DestinyClass.Unknown) return false;
      return true;
    }).toList();

    List<DestinyItemComponent> itemsToTransfer = items.where((item) {
      DestinyInventoryItemDefinition def = defs[item.itemHash];
      if (!unequippedIds.contains(item.itemInstanceId)) return false;
      if (character != null &&
          def.classType != character.classType &&
          def.classType != DestinyClass.Unknown) return false;
      return true;
    }).toList();

    List<String> idsToAvoid =
        (itemsToEquip + itemsToTransfer).map((item) => item.itemInstanceId).toList();

    for (var item in itemsToEquip) {
      String ownerId = profile.getItemOwner(item.itemInstanceId);
      DestinyInventoryItemDefinition def = defs[item.itemHash];
      if (ownerId == characterId) continue;
      if (def.nonTransferrable) continue;

      ItemDestination destination =
          character == null ? ItemDestination.Vault : ItemDestination.Character;
      await _transfer(item, ownerId, destination, characterId, idsToAvoid);
    }

    if (andEquip && itemsToEquip.length > 0) {
      _equipMultiple(itemsToEquip, characterId);
    }

    for (var item in itemsToTransfer) {
      String ownerId = profile.getItemOwner(item.itemInstanceId);
      DestinyInventoryItemDefinition def = defs[item.itemHash];
      if (ownerId == characterId) continue;
      if (def.nonTransferrable) continue;

      ItemDestination destination =
          character == null ? ItemDestination.Vault : ItemDestination.Character;
      await _transfer(item, ownerId, destination, characterId, idsToAvoid);
    }
    _debugInventory("loadout transfer completed");
    profile.fetchProfileData();
  }

  _debugInventory(String title) {
    print('------- $title --------');
    var characters = profile.getCharacters();
    characters.forEach((char) {
      var inventory = profile.getCharacterInventory(char.characterId);
      print("${char.characterId} = ${inventory.length}");
    });
    var profileInventory = profile
        .getProfileInventory()
        .where((item) => item.bucketHash == InventoryBucket.general);
    print("vault = ${profileInventory.length}");
  }

  Future<dynamic> _transfer(DestinyItemComponent item, String sourceCharacterId,
      ItemDestination destination,
      [String destinationCharacterId,
      List<String> idsToAvoid = const [],
      int stackSize]) async {
    var instanceInfo = profile.getInstanceInfo(item.itemInstanceId);
    var def = await manifest.getItemDefinition(item.itemHash);
    var sourceBucketDef = await manifest.getBucketDefinition(item.bucketHash);
    if (stackSize == null) {
      stackSize = item.quantity;
    }
    
    bool needsToUnequip = instanceInfo?.isEquipped ?? false;
    bool onVault = item.bucketHash == InventoryBucket.general;
    bool onPostmaster = item.bucketHash == InventoryBucket.lostItems;
    bool charToChar = !onVault && destination == ItemDestination.Character;
    bool needsVaulting =
        (charToChar && sourceCharacterId != destinationCharacterId) ||
            destination == ItemDestination.Vault;

    if (onPostmaster) {
      await _freeSlotsOnBucket(
          def.inventory.bucketTypeHash, sourceCharacterId, idsToAvoid);
      int result = await api.pullFromPostMaster(
          item.itemHash, stackSize, item.itemInstanceId, sourceCharacterId);
      if (result != 0) {
        throw TransferError(TransferErrorCode.cantPullFromPostmaster);
      }
      var destinationBucketDef =
          await manifest.getBucketDefinition(def.inventory.bucketTypeHash);

      if (def.inventory.isInstanceItem) {
        item.bucketHash = def.inventory.bucketTypeHash;
        sourceBucketDef = await manifest.getBucketDefinition(item.bucketHash);
        if (destinationBucketDef.scope == BucketScope.Account) {
          profile
              .getCharacterInventory(sourceCharacterId)
              .removeWhere((i) => i.itemInstanceId == item.itemInstanceId);
          profile.getProfileInventory().add(item);
        }
      } else if (stackSize >= item.quantity) {
        item.bucketHash = def.inventory.bucketTypeHash;
        sourceBucketDef = await manifest.getBucketDefinition(item.bucketHash);
        if (destinationBucketDef.scope == BucketScope.Account) {
          profile
              .getCharacterInventory(sourceCharacterId)
              .removeWhere((i) => i.itemHash == item.itemHash);
          profile.getProfileInventory().add(item);
        }
      } else {
        var newItem = DestinyItemComponent.fromMap(item.toMap());
        item.quantity = item.quantity - stackSize;
        newItem.quantity = stackSize;
        newItem.bucketHash = def.inventory.bucketTypeHash;
        item = newItem;
        if (destinationBucketDef.scope == BucketScope.Character) {
          profile.getCharacterInventory(sourceCharacterId).add(item);
        } else {
          profile.getProfileInventory().add(item);
        }
      }
      profile.fireLocalUpdate();

    }

    if (needsToUnequip) {
      await _unequip(item, sourceCharacterId, idsToAvoid);

    }

    if (needsVaulting) {
      int result = await api.transferItem(item.itemHash, stackSize, true,
          item.itemInstanceId, sourceCharacterId);
      if (result != 0) {
        
        throw new TransferError(TransferErrorCode.cantMoveToVault);
      }
      if (def.inventory.isInstanceItem) {
        item.bucketHash = InventoryBucket.general;
        if (sourceBucketDef.scope == BucketScope.Character) {
          profile
              .getCharacterInventory(sourceCharacterId)
              .removeWhere((i) => i.itemInstanceId == item.itemInstanceId);
          profile.getProfileInventory().add(item);
        }
        sourceBucketDef = await manifest.getBucketDefinition(item.bucketHash);
      } else if (stackSize >= item.quantity) {
        item.bucketHash = InventoryBucket.general;
        if (sourceBucketDef.scope == BucketScope.Character) {
          profile
              .getCharacterInventory(sourceCharacterId)
              .removeWhere((i) => i.itemHash == item.itemHash);
          profile.getProfileInventory().add(item);
        }
        sourceBucketDef = await manifest.getBucketDefinition(item.bucketHash);
      } else {
        var newItem = DestinyItemComponent.fromMap(item.toMap());
        item.quantity = item.quantity - stackSize;
        newItem.quantity = stackSize;
        item = newItem;
        profile.getProfileInventory().add(item);
      }
      onVault = true;
      profile.fireLocalUpdate();


    }

    if (onVault && destination != ItemDestination.Vault) {
      await _freeSlotsOnBucket(
          def.inventory.bucketTypeHash, destinationCharacterId, idsToAvoid);

      var destinationBucketDef =
          await manifest.getBucketDefinition(def.inventory.bucketTypeHash);
      if (destinationBucketDef.scope == BucketScope.Account) {
        destinationCharacterId = profile.getCharacters().first.characterId;
      }
      int result = await api.transferItem(item.itemHash, stackSize, false,
          item.itemInstanceId, destinationCharacterId);
      if (result != 0) {
        //TODO:implement error logic
        throw new TransferError(TransferErrorCode.cantMoveToCharacter);
      }

      if (def.inventory.isInstanceItem) {
        item.bucketHash = def.inventory.bucketTypeHash;
        if (destinationBucketDef.scope == BucketScope.Character) {
          profile
              .getProfileInventory()
              .removeWhere((i) => i.itemInstanceId == item.itemInstanceId);
          profile.getCharacterInventory(destinationCharacterId).add(item);
        }
      } else if (stackSize >= item.quantity) {
        item.bucketHash = def.inventory.bucketTypeHash;
        if (destinationBucketDef.scope == BucketScope.Character) {
          profile
              .getProfileInventory()
              .removeWhere((i) => i.itemHash == item.itemHash);
          profile.getCharacterInventory(destinationCharacterId).add(item);
        }
      } else {
        var newItem = DestinyItemComponent.fromMap(item.toMap());
        item.quantity = item.quantity - stackSize;
        newItem.quantity = stackSize;
        newItem.bucketHash = def.inventory.bucketTypeHash;
        item = newItem;
        if (destinationBucketDef.scope == BucketScope.Character) {
          profile.getCharacterInventory(sourceCharacterId).add(item);
        } else {
          profile.getProfileInventory().add(item);
        }
      }
      profile.fireLocalUpdate();
    }
  }

  _equip(DestinyItemComponent item, String characterId,
      [List<String> idsToAvoid = const []]) async {
    var blockingExotic = await _findBlockingExotic(item, characterId);
    if (blockingExotic != null) {
      await _unequip(blockingExotic, characterId, idsToAvoid);
    }
    List<DestinyItemComponent> equipment =
        profile.getCharacterEquipment(characterId);
    DestinyItemComponent currentlyEquipped =
        equipment.firstWhere((i) => i.bucketHash == item.bucketHash);
    int result = await api.equipItem(item.itemInstanceId, characterId);
    if (result != 0) {
      //TODO:implement error logic
      throw new TransferError(TransferErrorCode.cantEquip);
    }
    List<DestinyItemComponent> inventory =
        profile.getCharacterInventory(characterId);
    inventory.removeWhere((i) => i.itemInstanceId == item.itemInstanceId);
    equipment.removeWhere(
        (i) => i.itemInstanceId == currentlyEquipped.itemInstanceId);
    DestinyItemInstanceComponent iInfo =
        profile.getInstanceInfo(item.itemInstanceId);
    DestinyItemInstanceComponent sInfo =
        profile.getInstanceInfo(currentlyEquipped.itemInstanceId);
    iInfo.isEquipped = true;
    sInfo.isEquipped = false;
    equipment.add(item);
    inventory.add(currentlyEquipped);

    profile.fireLocalUpdate();
  }

  _equipMultiple(List<DestinyItemComponent> items, String characterId,
      [List<String> idsToAvoid = const []]) async {
    items = List.from(items);
    items.removeWhere((item){
      var instanceInfo = profile.getInstanceInfo(item.itemInstanceId);
      return instanceInfo.isEquipped;
    });
    for (var item in items) {
      var blocking = await _findBlockingExotic(item, characterId);
      if (blocking != null) {
        await _unequip(blocking, characterId, idsToAvoid);
      }
    }
    List<int> hashes = items.map((item)=>item.itemHash).toList();
    var defs = await manifest.getDefinitions<DestinyInventoryItemDefinition>(hashes);
    List<int> bucketHashes = defs.values.map((def){
      return def.inventory.bucketTypeHash;
    }).toList();
    
    Map<int, DestinyItemComponent> previouslyEquipped = {};
    List<DestinyItemComponent> charEquipment = profile.getCharacterEquipment(characterId);
    bucketHashes.forEach((bucketHash){
      previouslyEquipped[bucketHash] =  charEquipment.firstWhere((item)=>item.bucketHash == bucketHash);
    });
    List<String> itemIds = items.map((item) => item.itemInstanceId).toList();
    List<DestinyEquipItemResult> result = await api.equipItems(itemIds, characterId);
    charEquipment = profile.getCharacterEquipment(characterId);
    List<DestinyItemComponent> charInventory = profile.getCharacterInventory(characterId);
    result.forEach((result) {
      DestinyItemComponent newlyEquipped = profile.getItemsByInstanceId([result.itemInstanceId]).first;
      DestinyItemInstanceComponent newlyEquippedInstance = profile.getInstanceInfo(result.itemInstanceId);
      DestinyInventoryItemDefinition newlyEquippedDef = defs[newlyEquipped.itemHash];
      int bucketHash = newlyEquippedDef.inventory.bucketTypeHash;
      DestinyItemComponent previouslyEquippedItem = previouslyEquipped[bucketHash];
      DestinyItemInstanceComponent previouslyEquippedInstance = profile.getInstanceInfo(previouslyEquippedItem.itemInstanceId);
      if(result.equipStatus != 1 && result.equipStatus != 0){
        throw new TransferError(TransferErrorCode.cantEquip);
      }
      previouslyEquippedInstance.isEquipped = false;
      charEquipment.removeWhere((item)=>item.itemInstanceId == previouslyEquippedItem.itemInstanceId);
      charInventory.add(previouslyEquippedItem);
      
      newlyEquippedInstance.isEquipped = true;
      charInventory.removeWhere((item)=>item.itemInstanceId == result.itemInstanceId);
      charEquipment.add(newlyEquipped);
    });
  }

  _unequip(DestinyItemComponent item, String characterId,
      [List<String> idsToAvoid = const []]) async {
    DestinyItemComponent substitute =
        await _findSubstitute(item, characterId, idsToAvoid);
    int result = await api.equipItem(substitute.itemInstanceId, characterId);
    if (result != 0) {
      //TODO:implement error logic
      throw new TransferError(TransferErrorCode.cantUnequip);
    }
    List<DestinyItemComponent> inventory =
        profile.getCharacterInventory(characterId);
    List<DestinyItemComponent> equipment =
        profile.getCharacterEquipment(characterId);
    inventory.removeWhere((i) => i.itemInstanceId == substitute.itemInstanceId);
    equipment.removeWhere((i) => i.itemInstanceId == item.itemInstanceId);
    DestinyItemInstanceComponent iInfo =
        profile.getInstanceInfo(item.itemInstanceId);
    DestinyItemInstanceComponent sInfo =
        profile.getInstanceInfo(substitute.itemInstanceId);
    iInfo.isEquipped = false;
    sInfo.isEquipped = true;
    inventory.add(item);
    equipment.add(substitute);

    profile.fireLocalUpdate();
  }

  _freeSlotsOnBucket(
      int bucketHash, String characterId, List<String> idsToAvoid,
      [int count = 1]) async {
    DestinyInventoryBucketDefinition bucketDefinition =
        await manifest.getBucketDefinition(bucketHash);
    List<DestinyItemComponent> items;
    bool hasEquipSlot = bucketDefinition.category == BucketCategory.Equippable;
    if (bucketDefinition.scope == BucketScope.Character) {
      items = profile.getCharacterInventory(characterId);
    } else {
      items = profile.getProfileInventory();
    }
    items = items
        .where((item) =>
            item.bucketHash == bucketHash &&
            !idsToAvoid.contains(item.itemInstanceId))
        .toList();

    int bucketSize = bucketDefinition.itemCount - (hasEquipSlot ? 1 : 0);
    int itemCount = items.length;
    int freeSlots = bucketSize - itemCount;
    if (freeSlots > count) {
      return;
    }
    items.sort((itemA, itemB) {
      DestinyItemInstanceComponent instA =
          profile.getInstanceInfo(itemA.itemInstanceId);
      DestinyItemInstanceComponent instB =
          profile.getInstanceInfo(itemB.itemInstanceId);
      int powerA = instA?.primaryStat?.value ?? 0;
      int powerB = instB?.primaryStat?.value ?? 0;
      return powerA.compareTo(powerB);
    });
    for (var i = 0; i < count - freeSlots; i++) {
      await _transfer(items[i], characterId, ItemDestination.Vault);
    }
  }

  Future<DestinyItemComponent> _findBlockingExotic(
      DestinyItemComponent item, String characterId) async {
    DestinyInventoryItemDefinition def =
        await manifest.getItemDefinition(item.itemHash);
    if (def.inventory.tierType != TierType.Exotic) {
      return null;
    }
    if (![ItemType.armor, ItemType.weapon].contains(def.itemType)) {
      return null;
    }
    List<DestinyItemComponent> equipment =
        profile.getCharacterEquipment(characterId);
    Map<int, DestinyInventoryItemDefinition> definitions =
        await manifest.getDefinitions<DestinyInventoryItemDefinition>(
            equipment.map((pItem) => pItem.itemHash).toList());
    return equipment.firstWhere((i) {
      var d = definitions[i.itemHash];
      return d.itemType == def.itemType &&
          d.inventory.tierType == TierType.Exotic &&
          i.bucketHash != item.bucketHash;
    }, orElse: () => null);
  }

  Future<DestinyItemComponent> _findSubstitute(DestinyItemComponent item,
      String characterId, List<String> idsToAvoid) async {
    var itemDef = await manifest.getDefinition<DestinyInventoryItemDefinition>(item.itemHash);
    var character = profile.getCharacter(characterId);
    List<DestinyItemComponent> possibles = profile
        .getCharacterInventory(characterId)
        .where((pItem) =>
            item.bucketHash == pItem.bucketHash &&
            !idsToAvoid.contains(pItem.itemInstanceId))
        .toList();
    if (possibles.length == 0) {
      possibles = profile
          .getProfileInventory()
          .where((pItem) =>
              item.bucketHash == pItem.bucketHash &&
              !idsToAvoid.contains(pItem.itemInstanceId))
          .toList();
    }
    if (possibles.length == 0) {
      throw TransferError(TransferErrorCode.cantFindSubstitute);
    }
    Map<int, DestinyInventoryItemDefinition> definitions =
        await manifest.getDefinitions<DestinyInventoryItemDefinition>(
            possibles.map((pItem) => pItem.itemHash).toList());
    possibles.removeWhere((pItem) {
      var def = definitions[pItem.itemHash];
      if (def.inventory.tierType == TierType.Exotic
      && itemDef.inventory.tierType != TierType.Exotic) {
        return true;
      }
      if(def.classType != DestinyClass.Unknown && def.classType != character.classType){
        return true;
      }
      return false;
    });
    if (possibles.length == 0) {
      throw TransferError(TransferErrorCode.cantFindSubstitute);
    }
    possibles.sort((itemA, itemB) {
      DestinyItemInstanceComponent instA =
          profile.getInstanceInfo(itemA.itemInstanceId);
      DestinyItemInstanceComponent instB =
          profile.getInstanceInfo(itemB.itemInstanceId);
      int powerA = instA?.primaryStat?.value ?? 0;
      int powerB = instB?.primaryStat?.value ?? 0;
      return powerB.compareTo(powerA);
    });

    return possibles.first;
  }
}
