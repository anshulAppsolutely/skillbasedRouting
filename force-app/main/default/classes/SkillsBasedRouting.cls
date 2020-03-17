/***********************************************************************
 * Class Name: SkillsBasedRouting                                       *
 * Author: Alain Corsius                                                *
 * Date: Sep-2019                                                       *
 * Requirement/Project Name: KLM - CS Flow                              *
 * Requirement/Project Description:                                     *
 *                                                                      *
 * Invocable class for routing E&M CS cases to the appropriate agent    *
 * based on their related skills.                                       *
 *                                                                      *
 * Revision:                                                            *
 * - initial creation (sep 2019; JIRA=SFEMCS-173)                       *
 ***********************************************************************/
public without sharing class SkillsBasedRouting {
    static Map<String, Id> skillsMap = new Map<String, Id>();
    static Id channelId = [SELECT Id FROM ServiceChannel WHERE RelatedEntity = 'Case' LIMIT 1].Id;

    private static Integer hoursToDrop = 12; // A default value, but actually read from custom setting

    private static ID troubleshooter_QId = [select Id from Group where Type = 'Queue' and Name = 'Troubleshooter' limit 1].Id;

    private static final List<String> CS_US_PUSHABELE_TROUBLESHOOTER = new List<String>{'RA+','CI+', 'RA', 'CI'}; 

    @InvocableMethod(label='Skillbased routing' description='Repushes a case to an agent based on skills.')
    /**
     * routeUsingSkills routs a E&M CS Case to the SF user with the correct skills. The method must be invoked
     * from a process builder.
     * <p>
     * @param: List<String> cases The cases, that should be routed based on skills.
     * @return
     */
    public static void routeUsingSkills(List<String> cases) {

        //inset new Permset to current user
        PermissionSetAssignment permissionSetAssignment;

        for (Skill sk : [SELECT DeveloperName, Id FROM Skill limit 50]) {
            skillsMap.put(sk.Developername, sk.Id);
        }

        hoursToDrop = Integer.valueOf(E_M_CS_Settings__c.getInstance().Hours_To_Drop_Additional_Skill__c);

        // Get the correct E&M CS recoredtype Ids
        String emcsRecTypePrefix = CONSTANTS.RT_CASE_CS + '%';
        Set<Id> recTypeIds_EMCS = new Set<Id>(
            new Map<Id, RecordType>([SELECT Id FROM RecordType WHERE Developername LIKE :emcsRecTypePrefix]).keySet()
        );

        // Remove the old PendingServiceRouting
        List<PendingServiceRouting> lsPenSerRouCaseIds = [SELECT Id, WorkItemId FROM PendingServiceRouting WHERE WorkItemId IN :cases];
        if (lsPenSerRouCaseIds.size() > 0) {
            //assign Permission set
            //not required by Batch or Scheduler as it runs in system context and is scheduled by Admin - AA
            User currentLoggedInUser = [SELECT id, Profile.Name, Profile.Id FROM User WHERE ID = :UserInfo.getUserId()];
            permissionSetAssignment = assignEM_ModifyAllPerm(currentLoggedInUser);
            delete lsPenSerRouCaseIds;
        }

        Map<Id, Case> caseMap = new Map<Id, case>(
            [
                SELECT Id, Priority, CS_Aircraft_Type__c, Parent.CS_Aircraft_Type__c, Status, RecordTypeId, Push_to_Agent__c,
                       Parent.Account.Remote_Location__c, Account.Remote_Location__c, OwnerId,
                       Parent.Account.Transport_Time__c, Account.Transport_Time__c,
                       (Select Field, NewValue, OldValue, CreatedDate From Histories 
                               WHERE Field = 'Status' ORDER BY CreatedDate ASC) 
                FROM Case
                WHERE Id IN :cases AND RecordTypeId IN : recTypeIds_EMCS
            ]
        );
        Set<Id> cseToOmni = new Set<Id>();
        for (Case caseObj : caseMap.values()) {
            try {
                // System.debug('#### Handling ' + caseObj);

                //if Push to agent is trouble shooter, always push to omni, irrespective of status
                // system.debug('cse owner >>>'+caseObj.OwnerId);
                if (troubleshooter_QId == caseObj.OwnerId) {
                    // But only add a PSR, when it is a pushable troubleshooter
                    if (CS_US_PUSHABELE_TROUBLESHOOTER.contains(caseObj.Push_to_Agent__c)) {
                        System.debug('Added TBS for PSR: ' + caseObj.Id);
                        cseToOmni.add(caseObj.Id);
                    }
                    // else { System.debug('Removed for PSR: ' + caseObj.Id); }    
                    continue;
                }

                // if the status is not a "pushable" status, continue: troubleshooters are already added 
                if (!(CONSTANTS.CS_US_CI_PUSHABLE_STATUS.contains(caseObj.Status) || CONSTANTS.CS_US_RA_PUSHABLE_STATUS.contains(caseObj.Status))) {
                    // System.debug('#### State issue: CONSTANTS.CS_US_CI_PUSHABLE_STATUS.contains(' + caseObj.Status + ')=' + CONSTANTS.CS_US_CI_PUSHABLE_STATUS.contains(caseObj.Status));
                    // System.debug('#### State issue: CONSTANTS.CS_US_RA_PUSHABLE_STATUS.contains(' + caseObj.Status + ')=' + CONSTANTS.CS_US_RA_PUSHABLE_STATUS.contains(caseObj.Status));
                    System.debug('Removed for PSR: ' + caseObj.Id);
                    continue;
                }

                // Add cases which are not for Troubleshooter but based on status
                System.debug('Added regular for PSR: ' + caseObj.Id);
                cseToOmni.add(caseObj.Id);
            } catch (exception e) {
                System.debug('ERROR: ' + e.getStackTraceString());
                throw e;
            }
        }
        // Create a PendingServiceRouting to initiate routing
        // system.debug('cseToOmni >>>'+cseToOmni.size()+'cseToOmni >>>>'+cseToOmni);
        if (cseToOmni.size() > 0) {
            for (Id cseId : cseToOmni) {
                //the cases are pushed to omni one by one, not doing bulkification here
                createPendingServiceRouting(caseMap.get(cseId));
            }
        }

        //delete perm set
        if(permissionSetAssignment!=null){
            // system.debug('PermissionSetId >>>'+permissionSetAssignment);
            delete [SELECT Id from PermissionSetAssignment WHERE PermissionSetId = :permissionSetAssignment.PermissionSetId AND AssigneeId = :permissionSetAssignment.AssigneeId]; 
        }
    }

    /**
     * createPendingServiceRouting creates a PendingServiceRouting sObject with the correct SkillRequirement sObjects
     * related.
     * <p>
     * @param: Case caseObj The case, where PendingServiceRouting sObject is related to.
     * @return
     */
    static void createPendingServiceRouting(Case caseObj) {
        // System.debug('#### in createPendingServiceRouting '+ caseObj);
        Integer priority = caseObj.Priority == 'High' ? 20 : (caseObj.Priority == 'Medium' ? 50 : 90);

        // Decrease priority based on estimated transport time of the account
        priority -= claculatedTransportTimePriority(caseObj);

        Boolean isTroubleshooterCase = troubleshooter_QId == caseObj.OwnerId;

        if (caseObj.Status == CONSTANTS.CS_STATUS_EXC) {
            priority--;
        }
        if (isTroubleshooterCase && CONSTANTS.CS_US_TROUBLESHOOTER.contains(caseObj.Push_To_Agent__c)) {
            priority--;
        }

        // Create a new SkillsBased PendingServiceRouting
        PendingServiceRouting psrObj = new PendingServiceRouting(
            CapacityWeight = 1,
            IsReadyForRouting = false,
            RoutingModel = 'MostAvailable',
            RoutingPriority = priority,
            RoutingType = 'SkillsBased',
            ServiceChannelId = channelId,
            WorkItemId = caseObj.Id,
            PushTimeout = 0,
            DropAdditionalSkillsTimeout = hoursTodrop * 3600
        );
        insert psrObj;
        //psrObj = [SELECT id, IsReadyForRouting FROM PendingServiceRouting WHERE id = :psrObj.id];

        List<SkillRequirement> lsSkillreqs = new List<SkillRequirement>();

        // Now add SkillRequirement(s) to the PendingServiceRouting
        // First the type skill
        String skillId = getSkillIdType(caseObj.CS_Aircraft_Type__c == null ? caseObj.Parent.CS_Aircraft_Type__c : caseObj.CS_Aircraft_Type__c);
        if (skillId != null) {
            lsSkillreqs.add(new SkillRequirement(RelatedRecordId = psrObj.id, SkillId = skillId, SkillLevel = 1));
        }

        // Secondly the role skill
        Decimal requiredSkillLevel = 1;
        if (isTroubleshooterCase && CONSTANTS.CS_US_TROUBLESHOOTER.contains(caseObj.Push_To_Agent__c)) {
            requiredSkillLevel = 8;
        }
        lsSkillreqs.add(
            new SkillRequirement(RelatedRecordId = psrObj.id,
                                 SkillId = getSkillIdStatus(caseObj.Status, caseObj.Push_to_Agent__c, isTroubleshooterCase), 
                                 SkillLevel = requiredSkillLevel)
        );

        // Thirdly the outstation skill
		String outstation = caseObj.AccountId == null ? caseObj.Parent.Account.Remote_Location__c : caseObj.Account.Remote_Location__c;
		String skillOutId = getSkillIdOustation(outstation);
		if (skillOutId != null) {
			lsSkillreqs.add(new SkillRequirement(RelatedRecordId = psrObj.id, SkillId = skillOutId, SkillLevel = 1, IsAdditionalSkill = true));
		}

        if (lsSkillreqs.size() > 0) {
            insert lsSkillreqs;

            // Update PendingServiceRouting as IsReadyForRouting
            psrObj.IsReadyForRouting = true;
            update psrObj;
        }
    }

    /**
     * getSkillIdType gets the correct Skill Id, based on the aircraft type.
     * <p>
     * @param: String aircraftType The aircraft type.
     * @return
     */
    static String getSkillIdType(String aircraftType) {
        String skillName = '--';
        if (aircraftType != null) {
            if (aircraftType.contains('787')) {
                skillName = 'X787_Components';
            } else if (aircraftType.contains('747')) {
                skillName = 'X747_Components';
            } else if (aircraftType.contains('737')) {
                skillName = 'X737_Components';
            } else if (aircraftType.contains('777')) {
                skillName = 'X777_Components';
            } else if (aircraftType.contains('A330')) {
                skillName = 'A330_Components';
            }
        }

        return skillsMap.get(skillName);
    }

    /**
     * getSkillIdStatus gets the correct Skill Id, based on the case status.
     * <p>
     * @param: String status The case status.
     * @return
     */
    static String getSkillIdStatus(String status, String pushAgent, Boolean isTroubleshooterCase) {
        System.debug('Status & pushAgent & isTroubleshooterCase: ' + status + ' & ' + pushAgent + ' & ' + isTroubleshooterCase);

        String skillName = 'CS_RA';
        if (isTroubleshooterCase) {
            if ('CI+'.equalsIgnoreCase(pushAgent) || 'CI'.equalsIgnoreCase(pushAgent)) {
                skillName = 'CS_CI';
            } else if ('RA+'.equalsIgnoreCase(pushAgent) || 'RA'.equalsIgnoreCase(pushAgent)) {
                skillName = 'CS_RA';
            }
        }
        else {
            if (CONSTANTS.CS_US_CI_PUSHABLE_STATUS.contains(status)) {
                skillName = 'CS_CI';
            } else if (CONSTANTS.CS_US_RA_PUSHABLE_STATUS.contains(status)) {
                skillName = 'CS_RA';
            }
        }

        // System.debug('Calculated skillname: ' + skillName);

        return skillsMap.get(skillName);
    }

    /**
     * getSkillIdOustation gets the correct Skill Id, based on the case->account->outstation.
     * <p>
     * @param: String status The case status.
     * @return
     */
    static String getSkillIdOustation(String outstation) {
        String skillName = outstation + '_Outstation';
        return skillsMap.get(skillName);
    }

    /**
     * used to assign new Perm set to current user
     * @return
    */
    private static PermissionSetAssignment assignEM_ModifyAllPerm(User currentLoggedInUser){
        PermissionSetAssignment permissionSetAssignment;
        if (
            !System.isBatch() &&
            !System.isqueueable() &&
            !System.isScheduled() &&
            !CONSTANTS.EM_NOPERM_PROFILE.contains(currentLoggedInUser.Profile.Name)
        ) {
            PermissionSet[] permissionSet = [SELECT Id FROM PermissionSet WHERE Name = :CONSTANTS.EM_PERMSET LIMIT 1];
            if (permissionSet.size() > 0) {
                // no need to check FLS
                permissionSetAssignment = new PermissionSetAssignment(AssigneeId = currentLoggedInUser.Id, PermissionSetId = permissionSet[0].Id);
                // System.debug(permissionSetAssignment);
                //if already assigned, ignore error
                Database.insert(permissionSetAssignment, false);
            }
        }
        return permissionSetAssignment;
    }

    /**
     * claculatedTransportTimePriority calculate the number of priority level based on the estimated transport time from Account
     * to be decreased from the overall priority.
     * <p>
     * @param: Case The case.
     * @return 
     */
    private static  Integer claculatedTransportTimePriority(Case caseObj) {

        Integer transportTime = 0;
        if (caseObj.Parent != null && caseObj.Parent.Account != null && caseObj.Parent.Account.Transport_Time__c != null) {
            transportTime = caseObj.Parent.Account.Transport_Time__c.intValue();         
        } 
        else { return 0; }

        // First determine the datetime the US flow was started from Case History
        Datetime startDatetime = null;
        if (Test.isRunningTest()) { startDatetime = System.now(); }
        else {
            for (CaseHistory ch : caseObj.histories) {
                if (ch.OldValue == CONSTANTS.CS_STATUS_NWR && ch.NewValue != CONSTANTS.CS_STATUS_NWR) {
                    startDatetime = ch.createdDate;
                    // We only need the first change
                    break; 
                }
            }
        }

        if (startDatetime == null) { return 0; }

        Datetime estimatedArrivalTime = startDatetime.addDays(transportTime);

        /* Remember:
         * if the estematedArrivalTime is before today, #days is negative, otherwise positive
        */ 
        Integer days = (system.today()).daysBetween(Date.valueOf(estimatedArrivalTime));

        return days < 1 ? 7 : Math.max(8 - days, 0);
    }
}
