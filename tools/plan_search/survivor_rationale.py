"""Short post-survival decision summaries from visible packet facts and recorded code branches."""
def summarize(packet,trace):
    counts=trace['branch_counts'];strike=counts.get('hq_strike',0)+counts.get('no_field_target',0)
    if strike:goal='Pressure BLUE HQ with %d assigned units.'%strike
    elif counts.get('hq_threat',0):goal='Answer the packet\'s immediate HQ threats before allocating other engagements.'
    elif counts.get('opening_flank',0):goal='Use the configured flank opening toward waypoints derived from the known HQ position.'
    elif counts.get('opening_defend',0):goal='Hold the configured defensive opening before later HQ commitment.'
    elif counts.get('opening_regroup',0):goal='Regroup around the selected friendly anchor before committing farther forward.'
    elif counts.get('field_attack',0) or counts.get('raid',0):goal='Work through the known field targets using the configured preview scoring and focus limits.'
    elif counts.get('wounded_retreat',0) or counts.get('wounded_fortify',0):goal='Preserve units within the configured soldier-count threshold.'
    elif counts.get('reserve',0):goal='Keep the configured reserve near MY_HQ.'
    elif counts.get('unfavorable_hold',0):goal='Avoid engagements below the configured target-score floor.'
    else:goal='Use the configured stationary orders for units without a usable target.'
    bits=['Turn %s. %s'%(packet['turn'],goal)]
    priority={'hq_threat':0,'wounded_retreat':1,'wounded_fortify':1,'unfavorable_hold':2,'opening_flank':3,'opening_regroup':3,'reserve':3,'raid':4,'hq_strike':5,'field_attack':6,'hq_defense':7}
    chosen=sorted(trace['branches'].items(),key=lambda x:priority.get(x[1]['branch'],8))
    selected=[];seen=set()
    for uid,t in chosen:
        if t['branch'] in seen:continue
        seen.add(t['branch']);selected.append((uid,t))
        if len(selected)==3:break
    for uid,t in selected:
        b=t['branch'];f=t['facts']
        if b in ['field_attack','raid']:
            v=f['preview'];bits.append('%s %s %s: ETA %s, preview %.1f dealt/%.1f taken%s.'%(uid,'raids' if b=='raid' else 'attacks',f['target'],v['eta'],v['dealt'],v['taken'],(', %.1f fieldworks damage'%v['fw']) if v['fw'] else ''))
        elif b=='hq_threat':bits.append('%s intercepts %s (HQ threat ETA %s).'%(uid,f['enemy'],f['eta_strike_my_hq']))
        elif b=='hq_strike':bits.append('%s joins HQ pressure (ETA %s).'%(uid,f['eta']))
        elif b=='hq_defense':bits.append('%s %s to protect the HQ.'%(uid,'fortifies' if f['fortify_available'] else 'holds'))
        elif b=='wounded_retreat':bits.append('%s returns toward MY_HQ: %s soldiers is within the %s preservation threshold.'%(uid,f['soldiers'],f['threshold']))
        elif b=='wounded_fortify':bits.append('%s takes the stationary preservation order at %s soldiers.'%(uid,f['soldiers']))
        elif b=='reserve':bits.append('%s stays in the configured reserve near MY_HQ.'%uid)
        elif b=='opening_defend':bits.append('%s stays stationary during the opening through turn %s.'%(uid,f['opening_turns']))
        elif b=='opening_regroup':bits.append('%s moves toward friendly anchor %s.'%(uid,f['anchor']))
        elif b=='regroup_anchor':bits.append('%s holds the regroup anchor position.'%uid)
        elif b=='opening_flank':bits.append('%s moves to %s on the configured flank.'%(uid,f['destination']))
        elif b=='unfavorable_hold':bits.append('%s stays stationary: target score %.1f is below the configured floor %.1f.'%(uid,f['score'],f['floor']))
        elif b=='distant_regroup':bits.append('%s returns toward MY_HQ rather than pursuing the distant target (ETA %s).'%(uid,f['preview']['eta']))
        elif b=='no_field_target':bits.append('%s attacks ENEMY_HQ because no field-target preview is available.'%uid)
        else:bits.append('%s stays stationary with no usable target.'%uid)
    other={k:v for k,v in counts.items() if k not in seen}
    if other:bits.append('Other assigned branches: '+', '.join('%s %s'%(v,k.replace('_',' ')) for k,v in other.items())+'.')
    return ' '.join(bits)
